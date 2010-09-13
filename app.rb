%w(rubygems sinatra tropo-webapi-ruby open-uri json/pure helpers.rb).each{|lib| require lib}

use Rack::Session::Pool

post '/index.json' do
  v = Tropo::Generator.parse request.env["rack.input"].read
  session[:from] = v[:session][:from]
  session[:network] = v[:session][:to][:network]
  session[:channel] = v[:session][:to][:channel]
  t = Tropo::Generator.new
    if v[:session][:initial_text]
      t.ask :name => 'initial_text', :choices => { :value => "[ANY]"}
      session[:zip] = v[:session][:initial_text]
    else
      t.ask :name => 'zip', :bargein => true, :timeout => 60, :required => true, :attempts => 2,
          :say => [{:event => "timeout", :value => "Sorry, I did not hear anything."},
                   {:event => "nomatch:1 nomatch:2", :value => "Oops, that wasn't a five-digit zip code."},
                   {:value => "In what zip code would you like to search for volunteer opportunities in?."}],
                    :choices => { :value => "[5 DIGITS]"}
    end      
    
    t.on :event => 'hangup', :next => '/hangup.json'
    t.on :event => 'continue', :next => '/process_zip.json'
  t.response
end

post '/process_zip.json' do
  v = Tropo::Generator.parse request.env["rack.input"].read
  t = Tropo::Generator.new
    # if no intial text was captured, use the zip in response to the ask in the previous route
    session[:zip] = v[:result][:actions][:zip][:value].gsub(" ","") unless session[:zip]
    # construct and generate the params url. this is used for generating the JSON request, or in the case of twitter, the URL to the website.
    params = {
      :num => "9",
      :output => "json",
      :vol_loc => session[:zip],
      :vol_startdate => Time.now.strftime("%Y-%m-%d"),
      :vol_enddate => (Time.now+604800).strftime("%Y-%m-%d")
      }      
    params_str = ""
    params.each{|key,value| params_str << "&#{key}=#{value}"}
    # If using twitter, let's just give them a URL to the website. We don't want to flood Twitter with all the details we give voice/IM users
    if session[:network] == "TWITTER"
      t.say "Volunteer opportunities in your area for the next 7 days: #{tinyurl("http://www.allforgood.org/search?"+params_str)}"
      t.hangup
    end
    # Fetch JSON output for the volunter opportunities from our API provider, allforgood.org
    begin
      session[:data] = JSON.parse(open("http://www.allforgood.org/api/volopps?key=tropo"+params_str).read)
    rescue
      t.say "It looks like something went wrong with our volunteer data source. Please try again later."
      t.hangup
    end
    # List the opportunities to the user in the form of a question. The selected opp will be handled in the next route.
    if session[:data]["items"].size > 0
      t.say "Here are #{session[:data]["items"].size} opportunities. Press the opportunity number you want more information about."
      items_say = []
      session[:data]["items"].each_with_index{|item,i| items_say << "Opportunity ##{i+1} #{item["title"]}"}
      t.ask :name => 'selection', :bargein => true, :timeout => 60, :required => true, :attempts => 1,
          :say => [{:event => "nomatch:1", :value => "That wasn't a one-digit opportunity number. Here are your choices: "},
                   {:value => items_say.join(", ")}], :choices => { :value => "[1 DIGITS]"}
    else
      t.say "No volunteer opportunities found in that zip code. Please try again later."
    end
    
    t.on  :event => 'continue', :next => '/process_selection.json'    
    t.on  :event => 'hangup', :next => '/hangup.json'
  t.response  
end

post '/process_selection.json' do
  v = Tropo::Generator.parse request.env["rack.input"].read
  t = Tropo::Generator.new
    if v[:result][:actions][:selection][:value]
      item = session[:data]["items"][v[:result][:actions][:selection][:value].to_i-1]
      session[:say_string] = "" # storing in a session variable to send it via text message later (if the user wants)
      session[:say_string] += "Information about opportunity #{item["title"]} is as follows: "      
      session[:say_string] += "Event Details: " + construct_details_string(item)
      session[:say_string] += "Description: #{item["description"]}. End of description. " unless item["description"].empty?       
      t.say session[:say_string]
      t.ask :name => 'send_sms', :bargein => true, :timeout => 60, :required => true, :attempts => 1,
            :say => [{:event => "nomatch:1", :value => "That wasn't a valid answer. "},
                   {:value => "Would you like to have a text message sent to you?
                               Press or say 1 to get a text message, or press or say 'no' to conclude this session."}],
            :choices => { :value => "true(1,yes), false(2,no)"}
    else # no opportunity found
      t.say "No opportunity with that value. Please try again."
    end
    t.on  :event => 'continue', :next => '/send_text_message.json'
    t.on  :event => 'hangup', :next => '/hangup.json'
  t.response
end

post '/send_text_message.json' do
  v = Tropo::Generator.parse request.env["rack.input"].read
  t = Tropo::Generator.new
    if v[:result][:actions][:number_to_text] # they've told a phone # to texxt message
      t.message({
        :to => v[:result][:actions][:number][:value],
        :network => "SMS",
        :say => {:value => session[:say_string]}})
    else # we dont have a number, so either ask for it if they want to send a text message, or send to goodbye.json
      if v[:result][:actions][:send_sms][:value] == "true"
        t.ask :name => 'number_to_text', :bargein => true, :timeout => 60, :required => false, :attempts => 2,
              :say => [{:event => "timeout", :value => "Sorry, I did not hear anything."},
                     {:event => "nomatch:1 nomatch:2", :value => "Oops, that wasn't a 10-digit number."},
                     {:value => "What 10-digit phone number would you like to send the information to?"}],
                      :choices => { :value => "[10 DIGITS]"}
        next_url = '/send_text_message.json'
      end # no need for an else, send them off to /goodbye.json
    end
    
    next_url = '/goodbye.json' if next_url.nil?
    t.on  :event => 'continue', :next => next_url
    t.on  :event => 'hangup', :next => '/hangup.json'
  t.response
end

post '/goodbye.json' do
  v = Tropo::Generator.parse request.env["rack.input"].read
  t = Tropo::Generator.new
    if session[:channel] == "VOICE"
      t.say "That's all. Communication services donated by tropo dot com, data by all for good dot org. Have a nice day. Goodbye."
    else # for text users, we can give them a URL (most clients will make the links clickable)
      t.say "That's all. Communication services donated by http://Tropo.com; data by http://AllForGood.org"
    end 
    t.hangup
    
    t.on  :event => 'hangup', :next => '/hangup.json'
  t.response
end

post '/hangup.json' do
  v = Tropo::Generator.parse request.env["rack.input"].read
  puts " Call complete (CDR received). Call duration: #{v[:result][:session_duration]} second(s)"
end

##################
### WEB ROUTES ###
##################
get '/' do
  "
  <html>
    <head><title>Tropo Example App: Volunteer Opportunities by Phone</title></head>
    <body>
      <h2><em><a href='http://tropo.com/'>Tropo</a> + <a href='http://sinatrarb.com/'>Sinatra</a> + <a href='http://heroku.com'>Heroku</a> = Easy Ruby Communication Apps</em></h2>
      <h3>Steps to recreate</h3>
        <ol>
          <li>Sign up for a Tropo and Heroku Account</li>
          <li>Clone this application from Github and start up your Heroku app</li>
          <li>Create a Tropo application to point to your new Heroku app</li>
          <li>There is no step four!</li>
        </ol>
    </body>
  </html>
  "
end