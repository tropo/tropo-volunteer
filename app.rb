%w(rubygems sinatra tropo-webapi-ruby open-uri json/pure helpers.rb).each{|lib| require lib}

use Rack::Session::Pool

post '/index.json' do
  v = Tropo::Generator.parse request.env["rack.input"].read
  session[:caller] = v[:session][:from][:id]
  session[:network] = v[:session][:to][:network].upcase
  session[:channel] = v[:session][:to][:channel].upcase
  t = Tropo::Generator.new
    t.on :event => 'hangup', :next => '/hangup.json'
    t.on :event => 'continue', :next => '/process_zip.json'
    if v[:session][:initial_text] =~ /\d{5}/
      t.ask :name => 'initial_text_capture', :choices => { :value => "[ANY]"}
      session[:zip] = v[:session][:initial_text]
    else
      t.ask :name => 'zip', :bargein => true, :timeout => 60, :required => true, :attempts => 4,
          :say => [{:event => "timeout", :value => "Sorry, I did not hear anything."},
                   {:event => "nomatch:1 nomatch:2 nomatch:3", :value => "That wasn't a five-digit zip code."},
                   {:value => "In what zip code would you like to search for volunteer opportunities in?."}],
                    :choices => { :value => "[5 DIGITS]"}
    end
  t.response
end

post '/process_zip.json' do
  v = Tropo::Generator.parse request.env["rack.input"].read
  t = Tropo::Generator.new
    t.on  :event => 'hangup', :next => '/hangup.json'
    t.on  :event => 'continue', :next => '/process_selection.json'

    session[:zip] = v[:result][:actions][:zip][:value].gsub(" ","") unless session[:zip]        
    params = {
      :num => "9",
      :output => "json",
      :vol_loc => session[:zip],
      :vol_startdate => Time.now.strftime("%Y-%m-%d"),
      :vol_enddate => (Time.now+604800).strftime("%Y-%m-%d")
      }
      
    params_str = ""
    params.each{|key,value| params_str << "&#{key}=#{value}"}
    
    begin
      session[:data] = JSON.parse(open("http://www.allforgood.org/api/volopps?key=tropo"+params_str).read)
    rescue
      t.say "It looks like something went wrong with our volunteer data source. Please try again later. Goodbye."
      t.hangup
    end
    
    if session[:network] == "TWITTER"
      t.say "Volunteer opportunities in your area for the next 7 days: #{tinyurl("http://www.allforgood.org/search?"+params_str)}"
      t.hangup
    end

    if session[:data]["items"].size > 0
      t.say "Here are #{session[:data]["items"].size} opportunities. Press the opportunity number you want more information about."
      items_say = []
      session[:data]["items"].each_with_index{|item,i| items_say << "Opportunity ##{i+1} #{item["title"]}"}
      t.ask :name => 'selection', :bargein => true, :timeout => 60, :required => true, :attempts => 2,
          :say => [{:event => "nomatch:1 nomatch:2 nomatch:3", :value => "That wasn't a one-digit opportunity number."},
                   {:value => items_say.join(", ")}], :choices => { :value => "[1 DIGITS]"}
    else
      t.say "No volunteer opportunities found in that zip code. Please try calling back later. Goodbye."
    end
  t.response  
end

post '/process_selection.json' do
  v = Tropo::Generator.parse request.env["rack.input"].read
  t = Tropo::Generator.new
    t.on  :event => 'hangup', :next => '/hangup.json'
    if v[:result][:actions][:selection][:value]
      item = session[:data]["items"][v[:result][:actions][:selection][:value].to_i-1]
      tinyurl = shorten_url(URI.unescape(item["xml_url"]))
      
      t.say "Information about opportunity #{item["title"]} is as follows: "
      unless item["startDate"].empty? or item["endDate"].empty?
        t.say "From #{pretty_time(item["startDate"])} to #{pretty_time(item["endDate"])}"
      end
      
      if session[:channel] == "VOICE"
        t.say "Official web page: #{readable_tinyurl(tinyurl)}. Again, that's #{readable_tinyurl(tinyurl)}"
      else
        t.say "Official web page: #{tinyurl}"
      end
      contact_info = []
      contact_info << "Name: #{item["contactName"]}" unless item["contactName"].empty?
      contact_info << "Phone: #{item["contactPhone"]}" unless item["contactPhone"].empty?
      contact_info << "Email: #{item["contactEmail"]}" unless item["contactEmail"].empty?
      contact_info << "Street: #{item["street1"]}" unless item["street1"].empty?
      contact_info << "Street: #{item["street2"]}" unless item["street2"].empty?
      contact_info << "Lat/Long: #{item["latlong"]}" unless item["latlong"].empty? or session[:channel] == "VOICE"
      t.say "Contact/Location Info: #{contact_info.join(", ")}" unless contact_info.empty?
      t.say "Description: #{item["description"]}" 
    else
      t.say "No opportunity with that value. Please try again."
    end
    if session[:channel] == "VOICE"
      t.say "That's all. Communication services donated by tropo dot com, data by all for good dot org. Have a nice day. Goodbye."
    else
      t.say "That's all. Communication services donated by http://Tropo.com; data by http://AllForGood.org"
    end
    t.hangup
  t.response
end

post '/hangup.json' do
  v = Tropo::Generator.parse request.env["rack.input"].read
  puts " Call complete (CDR received). Call duration: #{v[:call][:duration]} second(s)"
end