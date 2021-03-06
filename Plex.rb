# encoding: utf-8

require 'socket'
require 'net/http'
require 'net/https'
require 'json'
require 'cgi'
require "rexml/document"
require 'base64'
include REXML

module Plex
  extend self
@@p = {}
@@Head = " HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: "
@@Path = File.expand_path(File.dirname(__FILE__))
@@Art = "http://cdn.wccftech.com/wp-content/uploads/2015/01/PlexMobile_512x512.png"
@@PlayonServer = ""

def GetPlayonAddress
  uri = URI.parse("http://m.playon.tv/q.php")
 #puts uri
  #r = Net::HTTP.start(uri.host, uri.port, :read_timeout => 10)
  http = Net::HTTP.new(uri.host, uri.port)
  req = Net::HTTP::Get.new(uri.request_uri)
  r = http.request(req).body.split("|")[0]
  uri = URI.parse("http://#{r}/images/search.png")
  res = Net::HTTP.start(uri.host, uri.port, :read_timeout => 1, :open_timeout => 1)
  puts res.to_s
  return r
rescue
  puts "Could not locate Playon Server. Continuing"
  return ""
end

puts "Playon Loading"
@@PlayonServer = GetPlayonAddress()
puts "PlayonServer : #{@@PlayonServer}"

def PlayonGET(url)
  puts url
  uri = URI.parse("http://#{@@PlayonServer}#{url}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.read_timeout = 500
  req = Net::HTTP::Get.new(uri.request_uri)
  r = http.request(req)
  #puts r.body
  return r.body.encode("ASCII", {:invalid => :replace, :undef => :replace, :replace => ''})
end

def KodiPost(pId,msg) #Should rename - only used for Kodi(player)
  h,p = pId.split(':')
  sock = TCPSocket.open(h,p)
  msg[:id]="1"
  msg[:jsonrpc]="2.0"
  msg = JSON.generate(msg)
  sock.write("POST /jsonrpc#{@@Head}#{msg.length}\r\n\r\n#{msg}")
  h = sock.gets("\r\n\r\n")
  /Content-Length: ([^\r\n]+)\r\n/.match(h)
  #puts h.inspect
  return JSON.parse(sock.read($1.to_i)) if $1
rescue
  puts $!, $@
  return nil
end

def SimpleGet(pId,url)
  uri = URI.parse(url)
  puts uri
  http = Net::HTTP.new(uri.host, uri.port)
  http.read_timeout = 500
  req = Net::HTTP::Get.new(uri.request_uri)
  r = http.request(req)
  return r.body
  if r.include?('Unauthorized')
    f = Dir["#{@@Path}/*#{pId.gsub(/[\.\:]/,'')}"]
    File.delete(f[0]) if f[0]
    @@p[pId] = nil
  end
rescue
  puts $!, $@
  return nil
end

def PlexGet(pId,msg) #plex server
  url = "http://#{@@p[pId][:server]}#{msg}"
  if url.include?('?')
    url << "&X-Plex-Token=#{@@p[pId][:token]}"
  else
    url << "?X-Plex-Token=#{@@p[pId][:token]}"
  end
  return SimpleGet(pId,url)
end


def PlayerGet(pId,msg) #plex HT
  url = "http://#{pId}#{msg}"
  if url.include?('?')
    url << "&X-Plex-Token=#{@@p[pId][:token]}"
  else
    url << "?X-Plex-Token=#{@@p[pId][:token]}"
  end
  return SimpleGet(pId,url)
end

#Savant Request Handling Below********************

def SavantRequest(hostname,cmd,req)
  #puts "Cmd: #{cmd}        Req: #{req.inspect}" unless req.include? "status"
  h = Hash[req.select { |e|  e.include?(":")  }.map {|e| e.split(":",2) if e && e.to_s.include?(":")}]
  pId = hostname["address"]
  unless @@p[pId]
    @@p[pId] = {}
    @@p[pId][:server] = hostname["server"] || hostname["address"]
    f = Dir["#{@@Path}/*#{pId.gsub(/[\.\:]/,'')}"]
    @@p[pId][:token],@@p[pId][:clientId] = /.+\/([^\.]+)\.(.+)/.match(f[0]).captures if f[0]
    r = Document.new PlexGet(pId,"")
    @@p[pId][:serverId] = r.root.attributes["machineIdentifier"]
  end  
  r = send(cmd,pId,h["id"] || "",h)
  #puts "Cmd: #{cmd}        Rep: #{r.inspect}" unless req.include? "status"
  return r
end

def TopMenu(pId,mId,parameters)
  puts "TopMenu"
  b = [{:id=>"Input",:cmd=>"Input",:text=>"Keyboard",:iInput=>true},{:id=>"/search?query=",:cmd=>"Search",:text=>"Search",:iInput=>true}]
  b.push(*GetPlexMenu(pId,"/library/sections"))
  b.push(*GetPlexMenu(pId,"/channels/all"))
  unless @@PlayonServer == "" && b.length > 2
    r = Document.new PlayonGET("/data/data.xml")
    r.elements["catalog"].each do |element| 
      b[b.length] = {
        :id =>element.attributes["href"],
        :cmd =>element.attributes["type"],
        :text =>element.attributes["name"],
        :icon =>"http://#{@@PlayonServer}#{element.attributes["art"]}"
      }
    end
  end
  return [{:id=>"Input",:cmd=>"GetPass",:text=>"Username",:iInput=>true}] unless b.length > 2
  return b
end

def Status(pId,mId,parameters)
  
  #puts "Command not supported: #{mId}"
  default = {:Artwork=>@@Art}
  r = KodiPost(pId,{:method => "Player.GetActivePlayers"})
  #puts r.inspect
  return default unless r && r["result"] && r["result"] != []
  playid = 1
  r["result"].each {|i| playid = i["playerid"]}
  @@p[pId][:playerId] = playid
  s = {
    :method => "Player.GetItem",
    :params => {
      :properties => [
        "art",
        "artist",
        "album",
        "season",
        "episode",
        "genre",
        "showtitle"
      ],
      :playerid => playid
    }
  }
  r = KodiPost(pId,s)["result"]
  #puts r.inspect
  return default unless r["item"] && r["item"].length > 0
  art = r["item"]["art"]["album.thumb"] ||\
      r["item"]["art"]["tvshow.thumb"] ||\
      r["item"]["art"]["poster"] ||\
      r["item"]["art"]["artist.fanart"] ||\
      r["item"]["art"]["fanart"] ||\
      r["item"]["art"]["thumb"]
  #puts art
  if art && (art.include?("127.0.0.1") || art.include?("plexserver"))
    art = URI.decode(URI.decode(URI.decode(art))).split("url=")[1]
    art.gsub!(/image:\/\/([^\/]+)\//,"image://#{@@p[pId][:server] || pId}/")
    art.gsub!("127.0.0.1:32400",@@p[pId][:server] || pId)
    if art.include?('?')
      art = "#{art}&X-Plex-Token=#{@@p[pId][:token]}"
    else
      art = "#{art}?X-Plex-Token=#{@@p[pId][:token]}"
    end
  end
  art ||= @@Art
  #puts art
  
  id = r["item"]["id"]
   
  i = [r["item"]["label"]]
  i << r["item"]["showtitle"] if (r["item"]["showtitle"]||"").length > 0
  i << r["item"]["album"] if (r["item"]["album"]||"").length > 0
  i << r["item"]["artist"].join(",") if (r["item"]["artist"]||"").length > 0
  if r["item"]["episode"].to_i > 0 && r["item"]["season"].to_i > 0
    i << "Season #{r["item"]["season"]} - Episode #{r["item"]["episode"]}"
  end
  i << r["item"]["genre"].join(",") if (r["item"]["genre"]||"").length > 0
  
  i = i.flatten.compact
  i.map{|e| e.gsub(/\P{ASCII}/, '')}
  s = {
    :method => "Player.GetProperties",
    :params => {
      :properties => [
        "playlistid",
        "speed",
        "position",
        "totaltime",
        "time"
      ],
      :playerid => playid
    }
  }
  r = KodiPost(pId,s)["result"]
  return default if r.nil?
  r["speed"] == 1 ? mode = "play" : mode = "pause"
  
  duration = r["totaltime"]["hours"]*60*60 + r["totaltime"]["minutes"]*60 + r["totaltime"]["seconds"]
  time = r["time"]["hours"]*60*60 + r["time"]["minutes"]*60 + r["time"]["seconds"]
   
  body = {
      :Mode => mode,
      :Id => id,
      :Time => time,
      :Duration => duration,
      :Info => i,
      :Artwork => art
    }
  return body
end

def ContextMenu(pId,mId,parameters)
 #puts "Command not supported: #{mId}"
  return nil
  
end

def NowPlaying(pId,mId,parameters)
 #puts "Command not supported: #{mId}"
  return nil
  
end

def AutoStart(pId,mId,parameters)
 #puts "Command not supported: #{mId}"
  return nil
  
end

def SkipToTime(pId,mId,parameters)
  t = parameters["time"].to_i
  s = t % 60
  m = (t / 60) % 60
  h = t / (60 * 60)
  KodiPost(pId,{
    :method => "Player.Seek",
    :params => {
      :playerid => @@p[pId][:playerId],
      :value => {
        :seconds => s,
        :minutes => m,
        :hours => h,
      }
    }
    })
  return nil
end

def TransportPlay(pId,mId,parameters)
  KodiPost(pId,{
    :method => "Player.PlayPause",
    :params => {
      :playerid => @@p[pId][:playerId],
      :play => "toggle"
    }
    })
  return nil
end

def TransportPause(pId,mId,parameters)
  KodiPost(pId,{
    :method => "Player.PlayPause",
    :params => {
      :playerid => @@p[pId][:playerId],
      :play => false
    }
    })
  return nil
end

def TransportStop(pId,mId,parameters)
  KodiPost(pId,{
    :method => "Player.Stop",
    :params => {
      :playerid => @@p[pId][:playerId]
    }
    })
  return nil
end

def TransportFastReverse(pId,mId,parameters)
  KodiPost(pId,{
    :method => "Player.SetSpeed",
    :params => {
      :playerid => @@p[pId][:playerId],
      :speed => "decrement"
    }
    })
  return nil
end

def TransportFastForward(pId,mId,parameters)
  KodiPost(pId,{
    :method => "Player.SetSpeed",
    :params => {
      :playerid => @@p[pId][:playerId],
      :speed => "increment"
    }
    })
  return nil
end

def TransportSkipReverse(pId,mId,parameters)
  KodiPost(pId,{
    :method => "Player.GoTo",
    :params => {
      :playerid => @@p[pId][:playerId],
      :to => "previous"
    }
    })
  return nil
end

def TransportSkipForward(pId,mId,parameters)
  KodiPost(pId,{
    :method => "Player.GoTo",
    :params => {
      :playerid => @@p[pId][:playerId],
      :to => "next"
    }
    })
  return nil
end

def TransportRepeatOn(pId,mId,parameters)
  KodiPost(pId,{
    :method => "Player.SetRepeat",
    :params => {
      :playerid => @@p[pId][:playerId],
      :repeat => "all"
    }
    })
  return nil
end

def TransportRepeatToggle(pId,mId,parameters)
  KodiPost(pId,{
    :method => "Player.SetRepeat",
    :params => {
      :playerid => @@p[pId][:playerId],
      :repeat => "cycle"
    }
    })
  return nil
end

def TransportRepeatOff(pId,mId,parameters)
  KodiPost(pId,{
    :method => "Player.SetRepeat",
    :params => {
      :playerid => @@p[pId][:playerId],
      :repeat => "off"
    }
    })
  return nil
end

def TransportShuffleToggle(pId,mId,parameters)
  KodiPost(pId,{
    :method => "Player.Shuffle",
    :params => {
      :playerid => @@p[pId][:playerId],
      :shuffle => "toggle"
    }
    })
  return nil
end

def TransportShuffleOn(pId,mId,parameters)
  KodiPost(pId,{
    :method => "Player.Shuffle",
    :params => {
      :playerid => @@p[pId][:playerId],
      :shuffle => true
    }
    })
  return nil
end

def TransportShuffleOff(pId,mId,parameters)
  KodiPost(pId,{
    :method => "Player.Shuffle",
    :params => {
      :playerid => @@p[pId][:playerId],
      :shuffle => false
    }
    })
  return nil
end

def TransportMenu(pId,mId,parameters)
  KodiPost(pId,{
    :method => "Input.Back",
    })
  return nil
end

def TransportUp(pId,mId,parameters)
  KodiPost(pId,{
    :method => "Input.Up",
    })
  return nil
end

def TransportDown(pId,mId,parameters)
  KodiPost(pId,{
    :method => "Input.Down",
    })
  return nil
end

def TransportLeft(pId,mId,parameters)
  KodiPost(pId,{
    :method => "Input.Left",
    })
  return nil
end

def TransportRight(pId,mId,parameters)
  KodiPost(pId,{
    :method => "Input.Right",
    })
  return nil
end

def TransportSelect(pId,mId,parameters)
  KodiPost(pId,{
    :method => "Input.Select",
    })
  return nil
end

def PowerOff(pId,mId,parameters)
  KodiPost(pId,{
    :method => "Player.Stop",
    :params => {
      :playerid => @@p[pId][:playerId]
    }
    })
  return nil
end

def PowerOn(pId,mId,parameters)
  KodiPost(pId,{
    :method => "Input.Up",
    })
  return nil
end

def VolumeUp(pId,mId,parameters)
  KodiPost(pId,{
    :method => "Application.SetVolume",
    :params => {
      :volume => "increment"
    }
    })
  return nil
end

def VolumeDown(pId,mId,parameters)
  KodiPost(pId,{
    :method => "Application.SetVolume",
    :params => {
      :volume => "decrement"
    }
    })
  return nil
end

def SetVolume(pId,mId,parameters)
  v = parameters["volume"].to_i
  KodiPost(pId,{
    :method => "Application.SetVolume",
    :params => {
      :volume => v
    }
    })
  return nil
end

def MuteOn(pId,mId,parameters)
  KodiPost(pId,{
    :method => "Application.SetMute",
    :params => {
      :mute => false
    }
    })
  return nil
end

def MuteOff(pId,mId,parameters)
  KodiPost(pId,{
    :method => "Application.SetMute",
    :params => {
      :mute => true
    }
    })
  return nil
end

def MuteOff(pId,mId,parameters)
  KodiPost(pId,{
    :method => "Application.SetMute",
    :params => {
      :mute => false
    }
    })
  return nil
end

#plugin defined requests below ************

def Input(pId,mId,parameters)
  t = parameters["search"]
  r = KodiPost(pId,{
    :method => "Input.SendText",
    :params => {
      :text => "#{t}",
      :done => true
    }
    })
  return nil
end

def Search(pId,mId,parameters)
  b = []
  s = URI.escape(parameters["search"])
  b.push(*GetPlexMenu(pId,"#{parameters["menu"]}#{s}"))
  return b
end

def Directory(pId,mId,parameters)
  b = []
  b.push(*GetPlexMenu(pId,mId))
  return b
end

def GetPlexMenu(pId,url)

  #puts url
  r = Document.new PlexGet(pId,url.gsub("%2526","%26"))
  b = []
  pThumb = r.root.attributes["thumb"]

  r.elements.each("MediaContainer/*") do |e|
    next unless e.name == "Track" || e.name == "Video" || e.name == "Directory"

    ic = e.attributes["thumb"]||pThumb||""
    ic = CGI::unescape(CGI::unescape(ic[/urls=(.+)/,1])) if ic.include?("urls=")
    ic = "http://#{@@p[pId][:server]}#{ic}" unless ic.nil? || ic.include?('http://') || ic.include?('https://')
    #ic = "http://#{@@p[pId][:server]}/photo/:/transcode?width=100&height=100&url=#{CGI::escape(ic)}"
    
    id = e.attributes["key"]
    id.gsub!('+','%20')
    id.gsub!("%26","%2526")
    id = "#{url}/#{id}/all" if url == "/library/sections"
    id = "#{url}/#{id}" unless id.include?("/")

    if ic.include?('?')
      ic = "#{ic}&X-Plex-Token=#{@@p[pId][:token]}"
    else
      ic = "#{ic}?X-Plex-Token=#{@@p[pId][:token]}"
    end

 
    if e.attributes["search"] == "1"
      b[b.length] = {
        :id =>"#{id}&query=",
        :cmd =>"Search",
        :text =>e.attributes["title"].gsub(/\P{ASCII}/, ''),
        :icon =>ic,
        :iInput=>true
      }
    else
      b[b.length] = {
        :id =>id,
        :cmd =>e.name,
        :text =>e.attributes["title"].gsub(/\P{ASCII}/, ''),
        :icon =>ic
      }
    end
  end
  return b
end

def Video(pId,mId,parameters)
  a,p= @@p[pId][:server].split(":")
  i = pId.gsub(/[\.\:]/,'')
  PlayerGet(pId,"/player/playback/playMedia?key=#{mId}&X-Plex-Client-Identifier=#{i}&machineIdentifier=#{@@p[pId][:serverId]}&address=#{a}&port=#{p}&protocol=http&path=#{mId}")
  return nil
end

def Video64(pId,mId,parameters)
  a,p= @@p[pId][:server].split(":")
  i = pId.gsub(/[\.\:]/,'')
  puts "\n\n\n#{mId}\n\n\n"
  mId = Base64.decode64(mId) 
  puts "\n\n\n#{mId}\n\n\n"
  
  

  PlayerGet(pId,"/player/playback/playMedia?key=#{mId}&X-Plex-Client-Identifier=#{i}&machineIdentifier=#{@@p[pId][:serverId]}&address=#{a}&port=#{p}&protocol=http&path=#{mId}")
  return nil
end

def Track(pId,mId,parameters)
  a,p= @@p[pId][:server].split(":")
  i = pId.gsub(/[\.\:]/,'')
  PlayerGet(pId,"/player/playback/playMedia?key=#{mId}&X-Plex-Client-Identifier=#{i}&machineIdentifier=#{@@p[pId][:serverId]}&address=#{a}&port=#{p}&protocol=http&path=#{mId}")
  return nil
end

def GetPass(pId,mId,parameters)
  @@p[pId][:username] = parameters["search"]
  return [{:id=>"Input",:cmd=>"SignIn",:text=>"Password",:iInput=>true}]
end


def SignIn(pId,mId,parameters)
  u = @@p[pId][:username]
  p = parameters["search"]
  uri = URI.parse("https://my.plexapp.com/users/sign_in.xml")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.verify_mode = OpenSSL::SSL::VERIFY_NONE
  request = Net::HTTP::Post.new(uri.request_uri)
  request.basic_auth(u, p)
  request["X-Plex-Client-Identifier"] = pId.gsub(/[\.\:]/,'')
  response = http.request(request)
  @@p[pId][:token] = response.body[/authenticationToken="([^"]+)"/,1]
  @@p[pId][:clientId] = pId.gsub(/[\.\:]/,'')
  r = Document.new PlexGet(pId,"")
  @@p[pId][:serverId] = r.root.attributes["machineIdentifier"]
  File.open("#{@@Path}/#{@@p[pId][:token]}.#{@@p[pId][:clientId]}","w"){}
  return TopMenu(pId,mId,parameters)
end

#Playon Menus

def folder(pId,mId,parameters)
  r = Document.new PlayonGET(mId)
  b = []
  art = r.root.attributes["art"]
  searchable = r.root.attributes["searchable"]
  art ||= "/images/folders/folder_2_0.png?rsm=pz&width=128&height=128&rst=16"
  b[0] = {:iInput=>1,:text=>"Search",:id=>mId,:cmd=>"psearch"} if searchable=="true"
  r.elements["group"].each do |element|
    l = b.length
    b[l] = {}
    b[l][:id] = element.attributes["href"]
    b[l][:text] = element.attributes["name"]
    b[l][:cmd] = element.attributes["type"]
    if art || element.attributes["art"]
      #b[l][:icon] ="http://#{@@PlayonServer}#{element.attributes["art"] || art}"
      b[l][:icon] ="http://#{@@PlayonServer}#{element.attributes["art"] || art}"
    end
  end
  return b
end


def video(pId,mId,parameters)
  a,p= @@p[pId][:server].split(":")
  i = pId.gsub(/[\.\:]/,'')
 #puts pId,mId
  r = Document.new PlayonGET(mId)
  b = [{
    :icon =>"http://#{@@PlayonServer}#{r.root.attributes["art"]}",
    :text => r.root.attributes["name"],
    :cmd => r.root.attributes["type"],
    :text => r.root.attributes["name"]
  }]
  src = r.elements["group"].elements["media"].attributes["src"]
  src = URI.escape("http://#{@@PlayonServer}/#{src}")
  puts src
  KodiPost(pId,{
    :method => "Player.Open",
    :params => {
      :item => {
        :file => src
      }
    }
    })
  KodiPost(pId,{
    :method => "Player.PlayPause",
    :params => {
      :playerid => @@p[pId][:playerId],
      :play => true
    }
    })
  #PlayerGet(pId,"/player/playback/playMedia?key=#{src}&X-Plex-Client-Identifier=#{i}&machineIdentifier=#{@@p[pId][:serverId]}&address=#{a}&port=#{p}&protocol=http&path=#{src}")
  return {}
end

def psearch(pId,mId,parameters)
  r = Document.new PlayonGET(mId+"&searchterm=dc:description%20contains%20"+URI.escape(parameters["search"]))
  b = []
  art = r.root.attributes["art"]
  searchable = r.root.attributes["searchable"]
  art ||= "/images/folders/folder_2_0.png?rsm=pz&width=128&height=128&rst=16"
  b[0] = {:iInput=>1,:text=>"Find"} if searchable=="true"
  r.elements["group"].each do |element|
    l = b.length
    b[l] = {}
    b[l][:id] = element.attributes["href"]
    b[l][:text] = element.attributes["name"]
    b[l][:cmd] = element.attributes["type"]
    if art || element.attributes["art"]
      #b[l][:icon] ="http://#{@@PlayonServer}#{element.attributes["art"] || art}"
      b[l][:icon] ="#{@@PlayonServer}#{element.attributes["art"] || art}"
    end
  end
  return b
end


end
