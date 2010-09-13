%w(rubygems sinatra tropo-webapi-ruby open-uri json/pure helpers.rb).each{|lib| require lib}

use Rack::Session::Pool

post '/index.json' do
  v = Tropo::Generator.parse request.env["rack.input"].read
  session[:from] = v[:session][:from]
  session[:network] = v[:session][:to][:network]
  session[:channel] = v[:session][:to][:channel]
  t = Tropo::Generator.new
    t.on :event => 'hangup', :next => '/hangup.json'
    t.on :event => 'continue', :next => '/process_zip.json'
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
  t.response
end

post '/process_zip.json' do
  v = Tropo::Generator.parse request.env["rack.input"].read
  t = Tropo::Generator.new
    t.on  :event => 'hangup', :next => '/hangup.json'
    t.on  :event => 'continue', :next => '/process_selection.json'
    
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
  t.response  
end

post '/process_selection.json' do
  v = Tropo::Generator.parse request.env["rack.input"].read
  t = Tropo::Generator.new
    t.on  :event => 'hangup', :next => '/hangup.json'
    if v[:result][:actions][:selection][:value]
      item = session[:data]["items"][v[:result][:actions][:selection][:value].to_i-1]
      
      t.say "Information about opportunity #{item["title"]} is as follows: "      
      t.say "Event Details: " + construct_details_string(item)
      t.say "Description: #{item["description"]}. End of description. " unless item["description"].empty? 

      t.message({
        :to => "15128267004",
        :network => "SMS",
        # :channel => session[:from][:channel],
        :say => {:value => "Test message"}})
      
      
    else # no opportunity found
      t.say "No opportunity with that value. Please try again."
    end
    
    if session[:channel] == "VOICE"
      t.say "That's all. Communication services donated by tropo dot com, data by all for good dot org. Have a nice day. Goodbye."
    else # for text users, we can give them a URL (most clients will make the links clickable)
      t.say "That's all. Communication services donated by http://Tropo.com; data by http://AllForGood.org"
    end 
    t.hangup
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