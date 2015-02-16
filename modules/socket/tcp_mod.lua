local C = require("cdef")
local ffi = require("ffi")
local ep = require("core.epoll_mod")
local timer = require("core.timer_mod")
local co = require("core.co_mod")
local utils = require("core.utils_mod")
local signal = require("core.signal_mod")
local dns = require("socket.dns_mod")
local dfa_compile = require("core.dfa").compile

local READ_ALL = 1
local READ_LINE = 2
local READ_LEN = 3
local READ_UNTIL = 4

local tcp_mt = {__index = {}}
local MAX_RBUF_LEN = 4096

local pools = {}

local YIELD_R = "co_r"
local YIELD_W = "co_w"

local function sock_io_handler(ev, events)
	local sock = ev.sock
	assert(sock)

	if bit.band(events, C.EPOLLIN) ~= 0 then
		if sock[YIELD_R] then
			co.resume(sock[YIELD_R])
		end
	elseif bit.band(events, C.EPOLLOUT) ~= 0 then
		if sock[YIELD_W] then
			co.resume(sock[YIELD_W])
		end
	elseif bit.band(events, C.EPOLLRDHUP) ~= 0 then
		if sock[YIELD_R] then
			co.resume(sock[YIELD_R])
			return
		elseif sock[YIELD_W] then
			co.resume(sock[YIELD_W])
			return
		end

		-- no waiting coroutine
		-- just unregister the event to avoid indefinite notify
		ep.del_event(ev)

		-- if the sock resides in some pool,
		-- then remove it from the pool and close it.
		if sock.prev then
			local pool
			if sock.pname then pool = pools[sock.pname] end
			if pool then
				sock.next.prev = pool
				pool.next = sock.next
				pool.size = pool.size - 1
				sock:close()
			end
		end
	end
end

local function tcp_new(fd)
	fd = fd or -1
	local ev = {fd=fd, handler=sock_io_handler}
	local sock = setmetatable({fd=fd, ev=ev, guard=utils.fd_guard(fd)}, tcp_mt)
	ev.sock = sock
	return sock
end

function tcp_mt.__index.yield(self, rw)
	if self[rw] then return "sock waiting" end
	self[rw] = coroutine.running()
	co.yield()
	self[rw] = nil
end

function tcp_mt.__index.close(self)
	if not self.closed then
		C.close(self.fd)
		self.guard.fd = -1
		self.closed = true
	else
		return nil, "closed"
	end
	return 1
end

function tcp_mt.__index.settimeout(self, msec)
	self.timeout = msec / 1000
end

local function receive_ll(self, pattern)
	if not self.rbuf_c then self.rbuf_c = ffi.new("char[?]", MAX_RBUF_LEN) end
	if not self.rbuf then self.rbuf = "" end

	local mode
	local typ = type(pattern)
	if typ == "function" then
		mode = READ_UNTIL
	elseif typ == 'number' then
		mode = READ_LEN
	elseif pattern == nil or pattern == '*l' then
		mode = READ_LINE
	elseif pattern == '*a' then
		mode = READ_ALL
	end

	while true do
		local rbuf_len = #self.rbuf
		if rbuf_len > 0 then
			if mode == READ_LINE then
				local la,lb = string.find(self.rbuf, "\r\n", 1, true)
				if la then
					local str = string.sub(self.rbuf, 1, la-1)
					self.rbuf = string.sub(self.rbuf, lb+1)
					return str
				end
			elseif mode == READ_LEN then
				if rbuf_len >= pattern then
					local str = string.sub(self.rbuf, 1, pattern)
					self.rbuf = string.sub(self.rbuf, pattern+1)
					return str
				end
			elseif mode == READ_UNTIL then
				local r,err
				self.rbuf,r,err = pattern(self.rbuf)
				if r or err then
					return r,err
				end
			end
		end

		while true do
			if self.rtimedout then
				local str = self.rbuf
				self.rbuf = ""
				return nil, "timeout", self.rbuf
			end

			local err
			local len = C.read(self.fd, self.rbuf_c, MAX_RBUF_LEN)
			local errno = ffi.errno()

			if len > 0 then
				self.rbuf = self.rbuf .. ffi.string(self.rbuf_c, len)
				break
			elseif len == 0 then
				self:close()
				err = "socket closed"
			elseif errno == EAGAIN then
				self:yield(YIELD_R)
			elseif errno ~= EINTR then
				self:close()
				err = utils.strerror(errno)
			end

			if err then
				local rbuf_len = #self.rbuf
				local str
				if rbuf_len > 0 then
					str = self.rbuf
					self.rbuf = ""
					if mode == READ_ALL then
						return str
					end
				end
				return nil, err, str
			end
		end
	end
end

function tcp_mt.__index.receive(self, pattern)
	if self.closed then return nil, "socket closed" end

	if self.reading then return nil,"socket busy reading" end
	self.reading = true

	self.rtimedout = false
	if self.timeout and self.timeout > 0 then
		self.rtimer = timer.add_timer(function()
			self.rtimedout = true
			if self[YIELD_R] then
				co.resume(self[YIELD_R])
			end
		end, self.timeout)
	end

	local r,err,partial = receive_ll(self, pattern)

	if self.rtimer then
		self.rtimer:cancel()
		self.rtimer = nil
	end

	self.reading = false
	return r,err,partial
end

function tcp_mt.__index.receiveuntil(self, pattern, options)
	if not pattern or pattern == "" then return nil, "empty pattern" end
	local inclusive = options and options.inclusive

	local dfa = dfa_compile(pattern)
	local node = dfa.start
	local data = ""
	local reset = false

	return function(size)
		assert(size == nil or size > 0)

		if reset then
			reset = false
			node = dfa.start
			if size then
				return nil
			end
		end

		if size and size <= #data then
			local r
			r = data:sub(1,size)
			data = data:sub(size+1)
			if node == dfa.last and #data == 0 then
				reset = true
			end
			return r
		elseif node == dfa.last then
			local r = data
			data = ""
			reset = true
			return r
		end

		return self:receive(function(rbuf)
			local idx = -1
			for i=1,#rbuf do
				idx = i
				node = node[rbuf:sub(i,i)]
				if not node then node = dfa.start
				elseif node == dfa.last then break end
			end

			if idx == #rbuf then
				data = data .. rbuf
				rbuf = ""
			else
				data = data .. rbuf:sub(1,idx)
				rbuf = rbuf:sub(idx+1)
			end

			local r
			local n_pat = node[3]
			if node ~= dfa.last then
				if size and size <= (#data - n_pat) then
					r = data:sub(1,size)
					data = data:sub(size+1)
				end
			else
				if size then
					local l = #data
					if not inclusive then l = l - n_pat end
					if size < l then
						r = data:sub(1,size)
						data = data:sub(size+1)
					end
				end
				if not r then
					if inclusive then r = data
					else r = data:sub(1, #data - n_pat) end
					data = ""
					reset = true
				end
			end
			return rbuf,r
		end)
	end
end

local MAX_IOVCNT = 64

local function flatten_table(self, data, idx, bytes)
	idx = idx or 0
	bytes = bytes or 0
	local iovec = self.iovec

	for i,v in ipairs(data) do
		local typ = type(v)
		if typ ~= "table" then
			if typ ~= "string" then v = tostring(v) end
			if idx == self.iovec_len then
				-- realloc the iovec array
				self.iovec_len = self.iovec_len + MAX_IOVCNT
				iovec = ffi.new("struct iovec[?]", self.iovec_len)
				ffi.copy(iovec, self.iovec, bytes)
				self.iovec = iovec
			end
			iovec[idx].iov_base = ffi.cast("void *", v)
			local len = #v
			iovec[idx].iov_len = len
			bytes = bytes + len
			idx = idx + 1
		else
			idx, bytes = flatten_table(self, v, idx, bytes)
			if idx == nil then return nil end
		end
	end

	return idx, bytes
end

local function send_ll(self, ...)
	if not self.iovec then
		self.iovec = ffi.new("struct iovec[?]", MAX_IOVCNT)
		self.iovec_len = MAX_IOVCNT
	end

	-- collect and flatten the arguments
	local n_iovec = 0
	local bytes = 0
	local data = select(1, ...)
	local n_args = select("#", ...)
	assert(n_args <= MAX_IOVCNT)
	local typ = type(data)
	if typ == "string" then
		n_iovec = n_args
		for i=0,n_args-1 do
			local s = select(i+1, ...)
			if type(s) ~= "string" then
				return nil, "invalid argument"
			end
			self.iovec[i].iov_base = ffi.cast("void *", s)
			local len = #s
			self.iovec[i].iov_len = len
			bytes = bytes + len
		end
	elseif typ == "table" then
		if n_args > 1 then return nil, "invalid argument" end
		n_iovec, bytes = flatten_table(self, data)
	end

	if n_iovec == nil or n_iovec == 0 or bytes == nil or bytes == 0 then
		return nil, "invalid argument"
	end

	-- do writev()
	local iovec = self.iovec
	local idx = 0
	local gc = {}
	local sent = 0
	while true do
		if self.wtimedout then
			return sent,"timeout"
		end
		local iovcnt = n_iovec % MAX_IOVCNT
		if iovcnt == 0 then iovcnt = MAX_IOVCNT end
		local len = C.writev(self.fd, iovec[idx], iovcnt)
		local errno = ffi.errno()
		if len > 0 then
			sent = sent + len
			if sent == bytes then return sent end
			for i=idx,idx+iovcnt-1 do
				if iovec[i].io_len <= len then
					len = len - iovec[i].io_len
					idx = idx + 1
					n_iovec = n_iovec - 1
					if len == 0 then break end
				else
					local str = string.sub(iovec[i].iov_base, len + 1)
					table.insert(gc, str)
					iovec[i].iov_base = ffi.cast("void*", str)
					iovec[i].iov_len = iovec[i].iov_len - len
					break
				end
			end
		elseif errno == EAGAIN then
			ep.add_event(self.ev, C.EPOLLOUT)
			self:yield(YIELD_W)
			ep.del_event(self.ev, C.EPOLLOUT)
		elseif errno ~= EINTR then
			self:close()
			return nil, utils.strerror(errno)
		end
	end
end

function tcp_mt.__index.send(self, ...)
	if self.closed then return nil, 'fd closed' end

	self.wtimedout = false
	if self.timeout and self.timeout > 0 then
		self.wtimer = timer.add_timer(function()
			self.wtimedout = true
			if self[YIELD_W] then
				co.resume(self[YIELD_W])
			end
		end, self.timeout)
	end

	local sent,err = send_ll(self, ...)

	if self.wtimer then
		self.wtimer:cancel()
		self.wtimer = nil
	end

	return sent,err
end

local function create_tcp_socket(self)
	assert(self.fd == -1)
	local fd = C.socket(C.AF_INET, C.SOCKET_STREAM, 0)
	assert(fd > 0)
	utils.set_nonblock(fd)
	self.fd = fd
	self.ev.fd = fd
	self.guard.fd = fd
end

function tcp_mt.__index.bind(self, ip, port)
	create_tcp_socket(self)
	local option = ffi.new("int[1]", 1)
	assert(C.setsockopt(self.fd, C.SOL_SOCKET, C.SO_REUSEADDR, ffi.cast("void*",option), ffi.sizeof("int")) == 0)
	local addr = ffi.new("struct sockaddr_in")
	addr.sin_family = C.AF_INET
	addr.sin_port = C.htons(tonumber(port))
	C.inet_aton(ip, addr.sin_addr)
	if C.bind(self.fd, ffi.cast("struct sockaddr*",addr), ffi.sizeof(addr)) == -1 then
		return nil, utils.strerror()
	end
	self.ip = ip
	self.port = port
	return 1
end

function tcp_mt.__index.listen(self, backlog, handler)
	backlog = backlog or 1000
	local ret = C.listen(self.fd, backlog)
	if ret ~= 0 then return nil, utils.strerror() end
	self.ev.handler = handler
	ep.add_event(self.ev, C.EPOLLIN)
	return 1
end

function tcp_mt.__index.accept(self)
	local addr = ffi.new("struct sockaddr_in[1]")
	local len = ffi.new("unsigned int[1]", ffi.sizeof(addr))
	local cfd = C.accept(self.fd, ffi.cast("struct sockaddr *",addr), len)
	if cfd <= 0 then return nil, utils.strerror() end
	local val = ffi.cast("unsigned short",C.ntohs(addr[0].sin_port))
	local port = tonumber(val)
	local ip = ffi.string(C.inet_ntoa(addr[0].sin_addr))
	local sock = tcp_new(cfd)
	sock.ip = ip
	sock.port = port
	if self.ip == "*" then
		assert(C.getsockname(cfd, ffi.cast("struct sockaddr *",addr), len) == 0)
		sock.srv_ip = ffi.string(C.inet_ntoa(addr[0].sin_addr))
	else
		sock.srv_ip = self.ip
	end
	sock.srv_port = self.port
	ep.add_event(sock.ev, C.EPOLLIN, C.EPOLLRDHUP, C.EPOLLET)
	return sock
end

function tcp_mt.__index.setkeepalive(self, timeout, size)
	if not self.pname then return nil, "not outgoing connection" end

	local pool = pools[self.pname]
	if not pool then
		pools[self.pname] = {size=0, maxsize=size or 30}
		pool = pools[self.pname]
		pool.prev = pool
		pool.next = pool
	end

	-- tail insert
	pool.prev.next = self
	self.prev = pool.prev
	self.next = pool
	if pool.size + 1 > pool.maxsize then
		-- remove the head (least recently used)
		pool.next.next.prev = pool
		pool.next = pool.next.next
	else
		pool.size = pool.size + 1
	end

	local timeout = timeout or 60
	if timeout > 0 then
		self.keepalive_timer = timer.add_timer(function()
			self.next.prev = self.prev
			self.prev.next = self.next
			self:close()
			pool.size = pool.size - 1
		end, timeout)
	end
	self.closed = true

	return 1
end

function tcp_mt.__index.connect(self, host, port, options_table)
	if self.connected then return nil, "already connected" end

	local pname
	if options_table then pname = options_table.pool end
	if not pname then pname = host .. ":" .. port end
	self.pname = pname

	-- look up the connection pool first
	local pool = pools[pname]
	if pool then
		local sock = pool.next
		if sock then
			sock.keepalive_timer:cancel()
			sock.keepalive_timer = nil

			-- copy fields
			self.ip = sock.ip
			self.port = sock.port
			self.fd = sock.fd
			self.ev = sock.ev
			self.ev.sock = self
			self.guard = sock.guard
			self.reusedtimes = sock.reusedtimes
			if not self.reusedtimes then self.reusedtimes = 0 end
			self.reusedtimes = self.reusedtimes + 1
			self.connected = true

			-- update the pool
			sock.next.prev = pool
			pool.next = sock.next
			pool.size = pool.size - 1
			return 1
		end
	end

	-- set connect timer
	self.wtimedout = false
	if self.timeout and self.timeout > 0 then
		self.wtimer = timer.add_timer(function()
			if self[YIELD_W] then
				self.wtimedout = true
				co.resume(self[YIELD_W])
			end
		end, self.timeout)
	end

	-- resolve host and/or port if needed
	if host:find("^%d+%.%d+%.%d+%.%d+$") == nil or type(port) ~= "number" then
		self.resolve_key = dns.resolve(host, port, function(ip, port)
			co.resume(self[YIELD_W], ip, port)
		end)
		host, port = self:yield(YIELD_W)
		local err
		if self.wtimedout then
			dns.cancel_resolve(self.resolve_key)
			self.resolve_key = nil
			err = "timeout"
		elseif host == nil or port == nil then
			err = "resolve failed"
		end
		if err then
			if self.wtimer then
				self.wtimer:cancel()
				self.wtimer = nil
			end
			return nil, err
		end
	end

	-- create a new socket
	create_tcp_socket(self)

	-- do non-blocking connect
	local err
	self.ip = host
	self.port = port
	local addr = ffi.new("struct sockaddr_in")
	addr.sin_family = C.AF_INET
	addr.sin_port = C.htons(tonumber(port))
	C.inet_aton(host, addr.sin_addr)
	while true do
		local ret = C.connect(self.fd, ffi.cast("struct sockaddr*",addr), ffi.sizeof(addr))
		local errno = ffi.errno()
		if ret == 0 then break end
		if errno == EINPROGRESS then
			ep.add_event(self.ev, C.EPOLLOUT, C.EPOLLIN, C.EPOLLRDHUP, C.EPOLLET)
			self:yield(YIELD_W)
			ep.del_event(self.ev, C.EPOLLOUT)
			if self.wtimedout then
				err = "timeout"
				break
			end
			local option = ffi.new("int[1]", 1)
			local len = ffi.new("int[1]", 1)
			assert(C.getsockopt(self.fd, C.SOL_SOCKET, C.SO_ERROR, ffi.cast("void*",option), len) == 0)
			if option[0] ~= 0 then
				err = utils.strerror(err)
			end
			break
		elseif errno ~= EINTR then
			err = utils.strerror(errno)
			break
		end
	end

	if self.wtimer then
		self.wtimer:cancel()
		self.wtimer = nil
	end

	if err then
		self:close()
		return nil, err
	end

	self.connected = true
	return 1
end

function tcp_mt.__index.getreusedtimes(self)
	return self.reusedtimes or 0
end

--#--

local g_listen_sk_tbl = {}
local g_tcp_cfg
local function tcp_parse_conf(cf)
	g_tcp_cfg = cf
	local srv_tbl = {}
	cf.srv_tbl = srv_tbl

	for _,srv in ipairs(cf) do
		if not srv.listen then
			srv.listen = {{address="*", port=80}}
		end
		for _,linfo in ipairs(srv.listen) do
			local port = linfo.port
			if not linfo.address then linfo.address = "*" end
			local address = linfo.address

			if not srv_tbl[port] then srv_tbl[port] = {} end

			if not srv_tbl[port][address] then
				srv_tbl[port][address] = {}
				if linfo.default_server then
					srv_tbl[port][address]["default_server"] = srv
				end
			end
			table.insert(srv_tbl[port][address], srv)
		end
	end

	-- setup all listen sockets
	for port,addresses in pairs(srv_tbl) do
		if addresses["*"] then
			local ssock = tcp_new()
			local r,err = ssock:bind("*", port)
			if err then error(err) end
			g_listen_sk_tbl[ssock.fd] = ssock
		else
			for address,_ in pairs(addresses) do
				local ssock = tcp_new()
				local r,err = ssock:bind(address, port)
				if err then error(err) end
				g_listen_sk_tbl[ssock.fd] = ssock
			end
		end
	end
end

local function tcp_handler(sock)
	local srv_list = g_tcp_cfg.srv_tbl[sock.srv_port][sock.srv_ip]
		or g_tcp_cfg.srv_tbl[sock.srv_port]["*"]
	local srv = srv_list[1]
	local handler = srv.handler
	if type(handler) == 'string' then
		return require(handler).service(srv)
	elseif type(handler) == 'function' then
		return handler(srv)
	end
end

local function do_all_listen_sk(func)
	for _,ssock in pairs(g_listen_sk_tbl) do
		func(ssock)
	end
end

local function run(cfg, parse_conf, overwrite_handler)
	local conn_handler = overwrite_handler or tcp_handler
	tcp_parse_conf(cfg)
	if parse_conf then parse_conf(cfg) end

	local worker_processes = g_tcp_cfg.worker_processes
	local sigchld_handler = function(siginfo)
		print ("> child exit with pid=" .. siginfo.ssi_pid .. ", status=" .. siginfo.ssi_status)
		worker_processes = worker_processes - 1
	end
	signal.add_signal_handler(C.SIGCHLD, sigchld_handler)

	-- avoid crash triggered by SIGPIPE
	signal.ignore_signal(C.SIGPIPE)

	for i=1,worker_processes do
		local pid = C.fork()
		if pid == 0 then
			print("child pid=" .. C.getpid() .. " enter")
			signal.del_signal_handler(C.SIGCHLD, sigchld_handler)

			local connections = 0
			local wait_listen_sk = false

			local ssock_handler = function(ev)
				local sock,err = ev.sock:accept()
				if sock then
					print("child pid=" .. C.getpid() .. " get new connection, cfd=" .. sock.fd .. ", port=" .. sock.port)
					connections = connections + 1
					if connections >= g_tcp_cfg.worker_connections then
						print("child pid=" .. C.getpid() .. " unlisten sk")
						do_all_listen_sk(function(ssock) ep.del_event(ssock.ev) end)
						wait_listen_sk = false
					end
					co.spawn(
						conn_handler,
						function()
							print("child pid=" .. C.getpid() .. " remove connection, cfd=" .. sock.fd)
							sock:close()
							connections = connections - 1
							if (not wait_listen_sk) and connections < g_tcp_cfg.worker_connections then
								print("child pid=" .. C.getpid() .. " listen sk")
								do_all_listen_sk(function(ssock) ep.add_event(ssock.ev, C.EPOLLIN) end)
								wait_listen_sk = true
							end
						end,
						sock
					)
				else
					print("child pid=" .. C.getpid() .. " accept error: " .. err)
				end
			end

			-- init the event loop
			ep.init()

			-- init signal subsystem
			signal.init()

			-- init timer subsystem
			timer.init()

			-- listen all server sockets
			do_all_listen_sk(function(ssock)
				local r,err = ssock:listen(100, ssock_handler)
				if err then error(err) end
			end)
			wait_listen_sk = true

			-- run the event loop
			ep.run()
			print("child pid=" .. C.getpid() .. " exit")
			os.exit(0)
		end
	end

	-- master event loop
	print("> parent wait " .. worker_processes .. " child")
	ep.init()
	ep.add_prepare_hook(function()
		assert(worker_processes >= 0)
		return -1, (worker_processes == 0)
	end)
	signal.init()
	ep.run()
	print "> parent exit"
	os.exit(0)
end

return setmetatable({
	new = tcp_new,
}, {
	__call = function(func, ...) return run(...) end
})
