#!/usr/bin/env ruby
# encoding: utf-8

require 'logger'
require 'socket'
require 'rubygems'
require 'json'

$Head = "HTTP/1.1 200 OK\r\nServer: Logitech Media Server\r\nContent-Length: 0\r\nContent-Type: application/json"
$NotFound = "HTTP/1.1 404 Not Found\r\n\r\n"

$blockSize = 1024
$server = TCPServer.open(9000)
$menuBuffer = {}


def LoadPlugin(pNm)
  if pNm.length > 0
    begin
      Object.const_get(pNm)
    rescue
      puts "Loading #{pNm}"
      begin
        f = File.expand_path(File.dirname(__FILE__)) + '/' + pNm
        require f
      rescue
        puts $!, $@
        puts "To unstable to continue without required plugins. Aborting"
      end
    end
  end
end

def ReadFromSavant(local)
  data = local.recv($blockSize)
  head,msg = data.split("\r\n\r\n")
  msg ||= ""
  iContent = /Content-Length: (\d+)/.match(data)
  if iContent && $1.to_i > msg.length
    while $1.to_i > msg.length
      msg << local.recv($1.to_i)
    end
  end
  return head,msg
rescue
  puts $!, $@
  return nil
end

def GetSavantReply(body)
  body = JSON.generate(body)
  #puts "LMS Reply:\n#{body}\n\n"
  head = $Head.sub(/Content-Length: \d+/,"Content-Length: #{body.length}")
  return "#{head}\r\n\r\n#{body}"
end

def EmptyBody
  b = {
    "params"=>[
      "",
      [
        "menu",
        "0",
        "999999999999999",
        "item_id:0"
      ]
    ],
    "method"=>"slim.request",
    "result"=>{
    "item_loop"=>[]
    }
  }
  return b
end

def MetaConnect(req)
  body = []
  case req
  when "/meta/handshake"
    body[0] = {
      "clientId"=>"ab5c9411",
      "supportedConnectionTypes"=>["long-polling","streaming"],
      "version"=>"1.0",
      "channel"=>"/meta/handshake",
      "advice"=>{"timeout"=>60000,"interval"=>0,"reconnect"=>"retry"},
      "successful"=>true
    }
  when "/meta/connect"
    body[0] = {
      "timestamp"=>Time.now.inspect,
      "clientId"=>"ab5c9411",
      "channel"=>"/meta/connect",
      "advice"=>{"interval"=>0},
      "successful"=>true
    }
  when "/meta/subscribe"
    body[0] = {
      "clientId"=>"ab5c9411",
      "channel"=>"/meta/subscribe",
      "subscription"=>"/ab5c9411/**",
      "successful"=>true
    }
  end
  return body
end

def ServerStatus()
  #I'm fairly sure savant confirms that the response is valid json and then ignores it.
  #Haven't taken the time to test it.
  return {
    "params"=>["",["serverstatus","0","999"]],
    "method"=>"slim.request",
    "id"=>"1",
    "result"=>{
      "other player count"=>0,
      "info total albums"=>0,
      "player count"=>1,
      "version"=>"7.7.4",
      "players_loop"=>[{
        "seq_no"=>0,
        "playerid"=>"",
        "displaytype"=>"none",
        "connected"=>1,
        "ip"=>"",
        "model"=>"squeezelite",
        "name"=>"Movie Player",
        "uuid"=>nil,
        "isplayer"=>1,
        "canpoweroff"=>1,
        "power"=>"1"
        }],
        "uuid"=>"ac4c8c61-92dc-4c08-ab93-0df4f1dd72e3",
        "sn player count"=>0,
        "info total artists"=>0,
        "info total songs"=>0,
        "lastscan"=>"1416161452",
        "info total genres"=>0
        }
      }
end

def CreateTopMenu(hostname,menuArray)
  body = {
    "params"=>[hostname,["menu","0","500","direct:1"]],
    "method"=>"slim.request",
    "result"=>{"item_loop"=>[]}}
  return body unless menuArray
  menuArray.each do |i|
    if i[:iInput]

      body["result"]["item_loop"][body["result"]["item_loop"].length] = {
        "actions"=> {
          "go"=> {
            "params"=> {
              "search"=> "__TAGGEDINPUT__",
              "menu"=> i[:id]
            },
            "cmd"=> ["cmd:#{i[:cmd]}"]
          }
        },
        "window"=> {
          "text"=> i[:text]
        },
        "input"=> {
          "len"=> 1,
          "processingPopup"=> {
            "text"=> "Searching..."
          },
        },
        "text"=> i[:text],
        "weight"=> 110,
        "node"=> "home",
        "id"=> i[:id]
      }
    else
      body["result"]["item_loop"][body["result"]["item_loop"].length] = {
        "actions"=>{"go"=>{
          "params"=>{:id=>i[:id],:args=>i[:args]},:cmd=>["cmd:#{i[:cmd]}"]
          }},
        "window"=>{"icon-id"=>i[:icon]},
        "node"=>"home",
        "text"=>i[:text]
        }
    end
  end
  return body
end

def CreateMenu(hostname,menuArray)
  body = {
    "params"=>["",["menu","0","999999999999999"]],
    "method"=>"slim.request",
    "result"=>{  
      "base"=>{  
        "actions"=>{
          "go"=>{  
            "params"=>{},
            "itemsParams"=>"params"
          },
          "more"=>{  
            "params"=>{},
            "itemsParams"=>"params",
            "window"=>{  
              "isContextMenu"=>1
            }
          }
        }
      },
      "item_loop"=>[]}}
  return body unless menuArray.respond_to?('each')
  menuArray.each do |i|
    if i[:iInput]
      body["result"]["item_loop"][body["result"]["item_loop"].length] = {
        "actions"=> {
          "go"=> {
            "params"=> {
              "search"=> "__TAGGEDINPUT__",
              "id"=>i[:id],
              "menu"=> i[:id]
            },
            "cmd"=> ["cmd:#{i[:cmd]}"]
          }
        },
        "window"=> {
          "titleStyle"=> "album"
        },
        "input"=> {
          "len"=> 1,
          "processingPopup"=> {
            "text"=> "Searching..."
          },
        },
        "text"=> i[:text],
        "weight"=> 110,
        "id"=> "opmlsearch"
      }
    else
      /([^\-\(\[]+)(.*)/.match(i[:text])
      i[:text] = "#{$1}\n#{$2}" if $1 && $2
      body["result"]["item_loop"][body["result"]["item_loop"].length] = {
        "params"=>{
          :cmd=>i[:cmd],
          :id=>i[:id],
          :args=>[i[:args]]
        },
        :text=>i[:text]
        }
      body["result"]["item_loop"][body["result"]["item_loop"].length-1][:icon]=i[:icon] if i[:icon]
      body["result"]["item_loop"][body["result"]["item_loop"].length-1][:presetParams]={} if i[:iContext]
    end
    if menuArray.length > 40 && i[:textKey]
      tk = (i[:text].delete("The ")[0] || "").upcase
      body["result"]["item_loop"][body["result"]["item_loop"].length-1][:textkey]=tk
    end
  end
 #puts JSON.pretty_generate(body)
  return body
end

def CreateContextMenu(hostname,menuArray)
  body = {
  "params"=>["",[]],
  "method"=>"slim.request",
  "result"=>{  
    "result"=>{"item_loop"=>[]}}}
  return body unless menuArray
    menuArray.each do |i|
      body["result"]["result"]["item_loop"][body["result"]["result"]["item_loop"].length] = {
        "actions"=>{"go"=>{
          "params"=>{:id=>i[:id],:args=>i[:args]},"cmd"=>[i[:cmd]]
        }},
        "text"=>i[:text]
        }
    end
  return body
end

def CreateNowPlaying(hostname,menuArray)
  body = {
  "params"=>["",[]],
  "method"=>"slim.request",
  "result"=>{  
    "result"=>{"item_loop"=>[]}}}
  return body unless menuArray
    menuArray.each do |i|
      body["result"]["result"]["item_loop"][body["result"]["result"]["item_loop"].length] = {
        "actions"=>{"go"=>{
          "params"=>{:id=>i[:id],:args=>i[:args]},"cmd"=>[i[:cmd]]
        }},
        "text"=>i[:text]
        }
    end
  return body
end

def CreateStatus(hostname,statusHash)
  
  body = {}
  statusHash ||= {:Mode=>"stop"}
  statusHash[:Info] = statusHash[:Info].to_a || []
  statusHash[:Info].each do |e|
    e.gsub!(/\P{ASCII}/, '') if e
  end
  body["id"] = statusHash[:Id] || ""
  body["result"] = {
    "seq_no"=>0,
    "mixer volume"=>statusHash[:Volume]||0,
    "mixer muting"=>1,
    "player_name"=>"player",
    "playlist_tracks"=>0,
    "player_connected"=>1,
    "playlist_tracks"=>1,
    "time"=>statusHash[:Time] || 0,
    "mode"=>statusHash[:Mode] || "pause",
    "signalstrength"=>0,
    "playlist shuffle"=>0,
    "playlist_timestamp"=>1,
    "remote"=>1,
    "rate"=>1,
    "can_seek"=>1,
    "power"=>1,
    "playlist repeat"=>0,
    "duration"=>statusHash[:Duration] || 0,
    "playlist mode"=>"off",
    "player_ip"=>"",
    "playlist repeat"=>0,
    "playlist_cur_index"=>"1",
    "playlist_loop"=>[{
      "playlist index"=>1,
      "id"=>statusHash[:Id] || "",
      "title"=>statusHash[:Info][0]||"",
      "coverid"=>statusHash[:Id]||"",
      "artist"=>statusHash[:Info][1]||"",
      "album"=>statusHash[:Info][2]||"",
      "duration"=>statusHash[:Duration] || 0,
      "tracknum"=>"1",
      #"year"=>player[:NowPlaying]["ProductionYear"],
      #"bitrate"=>player[:NowPlaying]["MediaStreams"][0]["BitRate"],
      #"url"=>player[:NowPlaying]["Path"],
      #"type"=>player[:NowPlaying]["Type"],
      "artwork_url"=>statusHash[:Artwork]||""
    }],
    "remoteMeta"=>{
      "id"=>statusHash[:Id]||"",
      "title"=>statusHash[:Info][0]||"",
      "coverid"=>statusHash[:Id]||"",
      "artist"=>statusHash[:Info][1]||"",
      "album"=>statusHash[:Info][1]||"",
      "duration"=>statusHash[:Duration]||0,
      "tracknum"=>"1",
      #"year"=>player[:NowPlaying]["ProductionYear"],
      #"bitrate"=>player[:NowPlaying]["MediaStreams"][0]["BitRate"],
      #"url"=>player[:NowPlaying]["Path"],
      #"type"=>player[:NowPlaying]["Type"],
      "artwork_url"=>statusHash[:Artwork]||""
    },
    "playlist shuffle"=>0,
    "current_title"=>statusHash[:Info][0]||"",
    "player_ip"=>""
  }
  return body
end

def SavantRequest(req)
  hstnm = req["params"][0]
  hostname = {}
  hstnm.scan(/([^:]+):([^,]+),?/).map {|x| hostname[x[0]]=x[1]}
  pNm = (hostname["plugin"]||"").capitalize
  LoadPlugin(pNm)
  req = req["params"][1]
  case 
  when req == ["version","?"] #fixed response not sure how much is needed
    body = {
    "params"=>["",["version","?"]],
    "method"=>"slim.request",
    "id"=>"1",
    "result"=>{"_version"=>"7.7.4"}
    }
  when req == ["serverstatus","0","999"]
    body = ServerStatus()
  when req.include?("xmlBrowseInterimCM:1") #Request for context popover menu
    cmd = "ContextMenu"
    body = CreateContextMenu(hostname,Object.const_get(pNm).SavantRequest(hostname,cmd,req))
  when req == ["menu","0","500","direct:1"] #top menu request.
    cmd = "TopMenu"
    body = CreateTopMenu(hostname,Object.const_get(pNm).SavantRequest(hostname,cmd,req))
  when req[0] == "status" && req[1] == "-" #Request for current title info and art
    cmd = "Status"
    body = CreateStatus(hostname,Object.const_get(pNm).SavantRequest(hostname,cmd,req))
  when req[0] == "status" && req[1] == "0" #Request for playlist or extended now playing options
    cmd = "NowPlaying"
    body = CreateNowPlaying(hostname,Object.const_get(pNm).SavantRequest(hostname,cmd,req))
  when req[0] == "playlist" && req[1] == "play"
    cmd = "AutoStart"
  when req[0] == "time"
    req[1] = "time:#{req[1]}"
    cmd = "SkipToTime"
  when req[0] == "play"
    cmd = "TransportPlay"
  when req[0] == "pause"
    cmd = "TransportPause"
  when req[0] == "stop" || (req[0] == "playlist" && req[1] == "clear")
    cmd = "TransportStop"
  when req[0] == "button" && req[1] == "scan_up"
    cmd = "TransportFastReverse"
  when req[0] == "button" && req[1] == "scan_down"
    cmd = "TransportFastForward"
  when req[0] == "button" && req[1] == "jump_rew"
    cmd = "TransportSkipReverse"
  when req[0] == "button" && req[1] == "jump_fwd"
    cmd = "TransportSkipForward"
  when req[0] == "button" && req[1] == "repeat_on"
    cmd = "TransportRepeatOn"
  when req[0] == "button" && req[1] == "repeat_toggle"
    cmd = "TransportRepeatToggle"
  when req[0] == "button" && req[1] == "repeat_off"
    cmd = "TransportRepeatOff"
  when req[0] == "button" && req[1] == "shuffle_on"
    cmd = "TransportShuffleOn"
  when req[0] == "button" && req[1] == "shuffle_off"
    cmd = "TransportShuffleOff"
  when req[0] == "button" && req[1] == "shuffle_toggle"
    cmd = "TransportShuffleToggle"
  when req[0] == "button" && req[1] == "play"
    cmd = "TransportPlay"
  when req[0] == "button" && req[1] == "pause"
    cmd = "TransportPause"
  when req[0] == "button" && req[1] == "menu"
    cmd = "TransportMenu"
  when req[0] == "button" && req[1] == "up"
    cmd = "TransportUp"
  when req[0] == "button" && req[1] == "down"
    cmd = "TransportDown"
  when req[0] == "button" && req[1] == "left"
    cmd = "TransportLeft"
  when req[0] == "button" && req[1] == "right"
    cmd = "TransportRight"
  when req[0] == "button" && req[1] == "select"
    cmd = "TransportSelect"
  when req[0] == "search" || req[0] == "Search"
    cmd = "Search"
  when req[0] == "input" || req[0] == "Input"
    cmd = "Input"
  when req[0] == "power" && req[1] == "0"
    cmd = "PowerOff"
  when req[0] == "power" && req[1] == "1"
    cmd = "PowerOn"
  when req[0] == "mixer" && req[1] == "volume" && req[2] == "+1"
    cmd = "VolumeUp"
  when req[0] == "mixer" && req[1] == "volume" && req[2] == "-1"
    cmd = "VolumeDown"
  when req[0] == "mixer" && req[1] == "volume"
    req[1] = req[1]+":"+req[2]
    cmd = "SetVolume"
  when req[0] == "mixer" && req[1] == "muting" && req[2] == "1"
    cmd = "MuteOn"
  when req[0] == "mixer" && req[1] == "muting" && req[2] == "0"
    cmd = "MuteOff"
  when req.find {|e| /cmd:([^"]+)/ =~ e} # if command is defined by plugin
    cmd = $1
  else
   puts "Request ignored:\n#{req}" 
  end
  if cmd && pNm && hostname && !body
    begin
      rep = Object.const_get(pNm).SavantRequest(hostname,cmd,req) unless body
    rescue 
      puts $!, $@
      #abort
    end
    body = CreateMenu(hostname,rep) unless rep.nil?
  end
  body ||= EmptyBody()
  return body
end

def ConnThread(local)
  head,msg = ReadFromSavant(local)
  #puts "Head: #{head},Message: #{msg}"
  #puts "Savant Request:\n#{head}\n#{msg}\n\n"
  if msg && msg.length > 4 && head.include?("json")
    req = JSON.parse(msg)
    case req
    when Array #some of the setup requests are arrays not
      body = MetaConnect(req[0]["channel"])
      #Netplayaudio.NetplayConnect(head,msg)
    when Hash
      body = SavantRequest(req)
    else
     puts "Unexpected result: #{req}"
    end
     #puts "Reply#{body}"
     reply = GetSavantReply(body)
    begin
      local.write(reply)
      local.close
    rescue 
      puts $!, $@
      puts "Reply failed. Savant Closed Socket. Continuing..."
    end
  else #savant could be asking for artwork, try and facilitate...
    r = ""
    #puts "Savant Request:\n#{head}\n#{msg}\n\n"
    begin
      uri = URI.parse(head[/GET \/?(h?t?t?p?:?\/?\/?[^ ]+) HTTP\/1.1/,1])
      http = Net::HTTP.new(uri.host, uri.port)
      req = Net::HTTP::Get.new(uri.request_uri)
      http.use_ssl = true if head.include?("https")
      r = http.request(req)
      b = r.body
      r = "HTTP/1.1 200 OK\r\nContent-Type: #{r["content-type"]}\r\nContent-Length: #{b.length}\r\n\r\n#{b}"
    rescue
      puts $!, $@
      r = $NotFound
    end
    begin
      local.write(r)
      local.close
    rescue
      puts $!, $@
      put "Write failed. Savant Closed Socket. Continuing..."
    end
  end
end

Thread.abort_on_exception = true #set false to increase longevity 

puts "Waiting for connection from Savant on port 9000. #{$server}"
loop do #Each savant request creates a new thread
  Thread.start($server.accept) { |local| ConnThread(local) }
end
