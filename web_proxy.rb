#!/usr/bin/env ruby

require 'socket'
require 'zlib'

# Global constants.
$DEFAULT_PORT = 80
$NUM_REQ_ARGS = 3
$MAX_CACHE_SIZE = 5000000
$MAX_OBJECT_SIZE = 1000000
$MAX_TIME = 3600
$COMPRESSION_LEVEL = 9

# Request class that holds information to a HTTP request.
class Request
    attr_accessor :type, :host, :port, :filename, :version, :timestamp

    def initialize(*args)
        @type, @host, @port, @filename, @version, @timestamp = *args
    end
end

# CacheLine class that allows us to cache page data.
class CacheLine
    attr_accessor :url, :response, :timestamp

    def initialize(*args)
        @url, @response, @timestamp = *args
    end
    
    def response
      @response # simply returning an instance variable @response
    end
end

# Proxy method.
def proxy(port)
    # Open a socket to the client - in this case, the browser.
    server = TCPServer.open("localhost", port)
    #puts "Server Started"

    cache = Hash.new()
    # Listen on the given port.
    loop do
        request = Array.new()
        headers = Hash.new()
        time = ""
        url = ""
   
        # Accept the client's connect.
        Thread.start(server.accept) do |socket|
          begin
            while line = socket.gets()
                line_parts = line.split()
                # Parsing the first 2 lines of the request.
                # Check if it is a valid GET request.
                if (line_parts[0].eql?("GET"))
                    url = line_parts[1]
                    request.push(line)
                    # Check if there is a Host line.
                elsif (line_parts[0].eql?("Host:"))
                    request.push(line)
                    time = Time.new()
                    req = parse_request(request, time)
                    # If there is a new line, we have reached the end and we get the headers.
                elsif (line.eql?("\r\n"))
                    header_str = parse_headers(headers)
                    break
                    # We keep adding the other headers into a hash map.
                else
                    colon_index = line.index(':')
                    headers[line[0, colon_index + 1]] = line[colon_index + 1, line.length]
                end
            end
    
            # If there is a cache hit, we retrieve from cache.
            if (cache.has_key?(url))
                #puts "We have a hit!"
                cacheObject = cache[url]
                socket.puts(inflate(cacheObject.response))
                # Else there is no cache hit.
                print "Cached: " + url + "\n";
            else
                response = openWebConn(req, header_str)
                encripted_response = deflate(response, $COMPRESSION_LEVEL)
                size = cacheSize(cache)
                # We check if the page request exceeds 1MB. If it is, we cache the page.
                if ((encripted_response.bytesize() <= $MAX_OBJECT_SIZE) &&
                    (size <= $MAX_CACHE_SIZE))
                    #puts "We have a miss!"
                    cache[url] = CacheLine.new(url, encripted_response, time)
                    socket.puts(response)
                    print "Just Cached: " + url + ". Cache free space is " + ($MAX_CACHE_SIZE - (size + encripted_response.bytesize())).to_s() + "\n";
                    # We check the cache size. If there is no more room for one more object,
                    # we delete the objects that have been in the cache for one hour or 
                    # more.
                    if (size + $MAX_OBJECT_SIZE > $MAX_CACHE_SIZE)
                        deleteCachedObjects(cache)
                    end
                    # Otherwise we don't cache the page.
                else
                    socket.puts(response)
                    print "Not Cached: " + url + "\n";
                end
            end
          rescue Exception => details
            print "Error: " + details + "\n"
          ensure  
            socket.close()
          end  
        end
    end
end

# Delete objects in the cache that are more than an hour old.
def deleteCacheObject(cache)
    cache.each_pair do |k, v|
        if (Time.parse(Time.new()) - Time.parse(v.timestamp) > $MAX_TIME)
            cache.delete(k)
        end
    end
end

# Returns the total size of the cache.
def cacheSize(cache)
    key = ""
    value = ""
    total_cache = ""
    i = 0
    cache.each_pair do |k, v|
        total_cache = total_cache + k + v.url + v.response + v.timestamp.asctime
        i += 1
    end
    total_cache.bytesize()
end

# Open a connection to the web server
def openWebConn(request, header_str)
    req = "GET #{request.filename} #{request.version}\r\n\r\n"
    socket = TCPSocket.open(request.host, request.port)
    socket.print(req)
    response = socket.read()
    socket.close()
    response
end

# Parses the headers of the request and makes modifications
def parse_headers(headers)
    str = ""
    headers.each_pair do |k, v|
        if (k.casecmp("Keep-Alive:") == 0)
        elsif (k.casecmp("Proxy-Connection:") == 0)
            str += "Proxy-Connection: Connection: close\r\n"
        else
            str = str + k + v
        end
    end
    str
end

# Parses first two lines of the GET request and creates a new Request objcet
def parse_request(request, time)
    host = ""
    port = ""
    filename = ""
    line_start = "http://"
    host_str = "Host: "

    # Check if request is a HTTP request
    if (!request[0].include?(line_start))
        raise "Malformed request line - only 'http' requests are supported"
    end

    # Check if request conforms to METHOD URL HTTP_VERSION
    req = request[0].split()
    if (req.length == $NUM_REQ_ARGS)
        # Check for 'GET' verb (kind of redundant since we checked it earlier in the
        # daryl_proxy method).
        if (!req[0].eql?"GET")
            raise "Request is not a 'GET' request. Ignored"
        end

        # Look for '/' that separates hostname and URI
        temp = req[1]
        uri = temp[line_start.length, temp.length()]
        slash_index = uri.index('/')
        if (slash_index.eql?(nil))
            filename = "/"
        else
            len = uri.length()
            filename = uri[slash_index, len]
        end

        # Look for ':' that separates hostname and port
        uri_no_filename = uri[0, slash_index]
        colon_index = uri.index(':')
        if (colon_index.eql?(nil))
            port = $DEFAULT_PORT
        else
            port = uri_no_filename[colon_index + 1, uri_no_filename.length()]
        end

        host = request[1]
        host = host[host_str.length(), host.length()]
        if (host.length.eql?(0))
            raise "Malformed request line - invalid host"
        end
    end
    request = Request.new("GET", host.chomp(), port, filename, "HTTP/1.0", time)
end

# aka compress
def deflate(string, level)
  if ($COMPRESSION_LEVEL != 0)
    z = Zlib::Deflate.new(level)
    dst = z.deflate(string, Zlib::FINISH)
    z.close
  else
    dst = string  
  end  
  dst
end

# aka decompress
def inflate(string)
  if ($COMPRESSION_LEVEL != 0)
    zstream = Zlib::Inflate.new
    buf = zstream.inflate(string)
    zstream.finish
    zstream.close
  else
    buf = string 
  end     
  buf
end

if __FILE__ == $0
    if (ARGV.length() != 1)
        abort("Usage: ruby proxy.rb <port>\n")
    else
        proxy(ARGV[0])
    end
end