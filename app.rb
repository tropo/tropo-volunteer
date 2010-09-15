%w(rubygems sinatra tropo-webapi-ruby open-uri json/pure helpers.rb).each{|lib| require lib}

use Rack::Session::Pool

# Resource called by the Tropo WebAPI URL setting http://skitch.com/jsgoecke/dsqew/tropo.com
post '/index.json' do
  # Fetch the HTTP Body (the session) of the POST and parse it into a native Ruby Hash object
  v = Tropo::Generator.parse request.env["rack.input"].read
  
  # Fetching certain variables from the resulting Ruby Hash of the session details
  # into Sinatra/HTTP sessions, this may then be used in the subsequent calls to the
  # Sinatra application
  session[:from] = v[:session][:from]
  session[:network] = v[:session][:to][:network]
  session[:channel] = v[:session][:to][:channel]
  
  # Create a Tropo::Generator object, that is used to build the resulting JSON response
  t = Tropo::Generator.new
    # If there is Inital Text available, we now this is an IM/SMS/Twitter session, and 
    # not voice
    if v[:session][:initial_text]
      # Add an 'ask' WebAPI method to the JSON resopnse with appropriate options
      t.ask :name => 'initial_text', :choices => { :value => "[ANY]"}
      # Set a session variable with the Zip the user sent when they sent the IM/SMS/Twitter 
      # Request
      session[:zip] = v[:session][:initial_text]
    else
      # If this is a voice session, then add an ask to the JSON response that is voice oriented
      # with the appropriate options
      t.ask :name => 'zip', :bargein => true, :timeout => 60, :required => true, :attempts => 2,
          :say => [{:event => "timeout", :value => "Sorry, I did not hear anything."},
                   {:event => "nomatch:1 nomatch:2", :value => "Oops, that wasn't a five-digit zip code."},
                   {:value => "Please enter your zip code to search for volunteer opportunities in your area."}],
                    :choices => { :value => "[5 DIGITS]"}
    end      
    
    # Add a 'hangup' to the JSON reponse, set which resource to go to if a Hangup event occurs on Tropo
    t.on :event => 'hangup', :next => '/hangup.json'
    # Add an 'on' to the JSON reponse, set which resource to go when the 'ask' is done executing
    t.on :event => 'continue', :next => '/process_zip.json'
  
  # Return the JSON response via HTTP to Tropo
  t.response
end

# This is the resource that the next step in the session is posted to when the 'ask' is completed 
# in 'index.json'
post '/process_zip.json' do
  # Fetch the HTTP Body (the session) of the POST and parse it into a native Ruby Hash object
  v = Tropo::Generator.parse request.env["rack.input"].read
  
  # Create a Tropo::Generator object, that is used to build the resulting JSON response
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
      # Add a 'say' to the JSON response
      t.say "Volunteer opportunities in your area for the next 7 days: #{tinyurl("http://www.allforgood.org/search?"+params_str)}"
      # Add a 'hangup' to the JSON response
      t.hangup
    end
    # Fetch JSON output for the volunter opportunities from our API provider, allforgood.org
    begin
      session[:data] = JSON.parse(open("http://www.allforgood.org/api/volopps?key=tropo"+params_str).read)
    rescue
      # Add a 'say' to the JSON response
      t.say "It looks like something went wrong with our volunteer data source. Please try again later."
      t.hangup
    end
    # List the opportunities to the user in the form of a question. The selected opp will be handled in the next route.
    if session[:data]["items"].size > 0
      # Add a 'say' to the JSON response
      t.say "Here are #{session[:data]["items"].size} opportunities. Press the opportunity number you want more information about."
      items_say = []
      session[:data]["items"].each_with_index{|item,i| items_say << "Opportunity ##{i+1} #{item["title"]}"}
      # Add an 'ask' to the JSON response
      t.ask :name => 'selection', :bargein => true, :timeout => 60, :required => true, :attempts => 1,
          :say => [{:event => "nomatch:1", :value => "That wasn't a one-digit opportunity number. Here are your choices: "},
                   {:value => items_say.join(", ")}], :choices => { :value => "[1 DIGITS]"}
    else
      # Add a 'say' to the JSON response
      t.say "No volunteer opportunities found in that zip code. Please try again later."
    end
    
    # Add an 'on' to the JSON reponse, set which resource to go when the 'ask' is done executing
    t.on  :event => 'continue', :next => '/process_selection.json'
    # Add a 'hangup' to the JSON reponse, set which resource to go to if a Hangup event occurs on Tropo
    t.on  :event => 'hangup', :next => '/hangup.json'
    
  # Return the JSON response via HTTP to Tropo
  t.response  
end

# This is the resource that the next step in the session is posted to when the 'ask' is completed 
# in 'process_zip.json'
post '/process_selection.json' do
  # Fetch the HTTP Body (the session) of the POST and parse it into a native Ruby Hash object
  v = Tropo::Generator.parse request.env["rack.input"].read
  
  # Create a Tropo::Generator object, that is used to build the resulting JSON response
  t = Tropo::Generator.new
    # If we have a valid response from the last ask, do this section
    if v[:result][:actions][:selection][:value]
      item = session[:data]["items"][v[:result][:actions][:selection][:value].to_i-1]
      session[:say_string] = "" # storing in a session variable to send it via text message later (if the user wants)
      session[:say_string] += "Information about opportunity #{item["title"]} is as follows: "      
      session[:say_string] += "Event Details: #{construct_details_string(item)} "
      session[:say_string] += "Description: #{item["description"]}. End of description. " unless item["description"].empty?       
      t.say session[:say_string]

      # Ask the user if they would like an SMS sent to them
      t.ask :name => 'send_sms', :bargein => true, :timeout => 60, :required => true, :attempts => 1,
            :say => [{:event => "nomatch:1", :value => "That wasn't a valid answer. "},
                   {:value => "Would you like to have a text message sent to you?
                               Press 1 or say 'yes' to get a text message; Press 2 or say 'no' to conclude this session."}],
            :choices => { :value => "true(1,yes), false(2,no)"}
    else # no opportunity found
      t.say "No opportunity with that value. Please try again."
    end
    
    # Add an 'on' to the JSON reponse, set which resource to go when the 'ask' is done executing
    t.on  :event => 'continue', :next => '/send_text_message.json'
    # Add a 'hangup' to the JSON reponse, set which resource to go to if a Hangup event occurs on Tropo
    t.on  :event => 'hangup', :next => '/hangup.json'
    
  # Return the JSON response via HTTP to Tropo
  t.response
end

# This is the resource that the next step in the session is posted to when the 'ask' is completed 
# in 'process_selection.json'
post '/send_text_message.json' do
  # Fetch the HTTP Body (the session) of the POST and parse it into a native Ruby Hash object
  v = Tropo::Generator.parse request.env["rack.input"].read
  
  # Create a Tropo::Generator object, that is used to build the resulting JSON response
  t = Tropo::Generator.new
    if v[:result][:actions][:number_to_text] # they've told a phone # to texxt message
      t.message({
        :to => v[:result][:actions][:number_to_text][:value],
        :network => "SMS",
        :say => {:value => session[:say_string]}})
      t.say "Message sent."
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
    
    # Tell it to say goodbye if there is no next_url set above
    next_url = '/goodbye.json' if next_url.nil?
    # Add an 'on' to the JSON reponse, set which resource to go when the 'ask' is done executing
    t.on  :event => 'continue', :next => next_url
    # Add a 'hangup' to the JSON reponse, set which resource to go to if a Hangup event occurs on Tropo
    t.on  :event => 'hangup', :next => '/hangup.json'
  
  # Return the JSON response via HTTP to Tropo
  t.response
end

# This is the resource that the next step in the session is posted to when the 'ask' is completed 
# in 'send_text_message.json'
post '/goodbye.json' do
  # Fetch the HTTP Body (the session) of the POST and parse it into a native Ruby Hash object
  v = Tropo::Generator.parse request.env["rack.input"].read
  
  # Create a Tropo::Generator object, that is used to build the resulting JSON response
  t = Tropo::Generator.new
    if session[:channel] == "VOICE"
      t.say "That's all. Communication services donated by tropo dot com, data by all for good dot org. Have a nice day. Goodbye."
    else # for text users, we can give them a URL (most clients will make the links clickable)
      t.say "That's all. Communication services donated by http://Tropo.com; data by http://AllForGood.org"
    end 
    t.hangup
    
    # Add a 'hangup' to the JSON reponse, set which resource to go to if a Hangup event occurs on Tropo
    t.on  :event => 'hangup', :next => '/hangup.json'
  t.response
end

# This is the resource that the next step in the session is posted to when any of the resources do a hangup
post '/hangup.json' do
  v = Tropo::Generator.parse request.env["rack.input"].read
  puts " Call complete (CDR received). Call duration: #{v[:result][:session_duration]} second(s)"
end

##################
### WEB ROUTES ###
##################
get '/' do
  # TO DO - HAML/SASS
  "
<html>
  <head><title>Tropo Example App: Volunteer Opportunities by Phone</title></head>
  <body>
    <h2><em><a href='http://tropo.com/'>Tropo</a> + <a href='http://sinatrarb.com/'>Sinatra</a> + <a href='http://heroku.com'>Heroku</a> = Easy Ruby Communication Apps</em></h2>
    <h3>Steps to recreate</h3>
      <ol>
        <li>Sign up for a <a href='http://api.heroku.com/signup'>Heroku Account</a> and install the gem:</li>
          <ul>
            <li>If you haven't already, you'll first need to install <a href='http://www.ruby-lang.org/en/downloads/'>Ruby</a>, <a href='http://docs.rubygems.org/read/chapter/3'>Rubygems</a>, and <a href='http://book.git-scm.com/2_installing_git.html'>Git</a> on your computer.</li>
            <li>Once all the prerequisites are installed, next you'll run <span style='font-family: monospace;'>gem install heroku</span> <span style='font-size:90%'><i>(Windows)</i></span> or <span style='font-family: monospace;'>sudo gem install heroku</span> <span style='font-size:90%'><i>(OSX/Linux)</i></span> from the command line.</li>
          </ul>
        <li>Clone this application from Github and start up your Heroku app</li>
          <ul>
            <li>Enter this into your computer's command line to download the sample Tropo application: <span style='font-family: monospace;'>git clone git@github.com:tropo/tropo-volunteer.git --depth 1</span></li> 
            <li>Next, enter the app's directory: <span style='font-family: monospace;'>cd tropo-volunteer/</span></li>
            <li>Create your Heroku app; if you do not define a name at the end of this line, Heroku will auto-generate one for you: <span style='font-family: monospace;'>heroku create</span></li>
            <li>Last, send your new application up to the Heroku cloud: <span style='font-family: monospace;'>git push heroku master</span></li>
            <li>You can now view your application by going to it's URL or by typing <span style='font-family: monospace;'>heroku open</span> from the command line.  You can find the application's URL by typing <span style='font-family: monospace;'>heroku info</span> or by logging into Heroku and clicking on your application in <b>My Apps</b>. 
          </ul>
        <li><a href='https://www.tropo.com/account/register.jsp'>Sign up</a> and create your first Tropo WebAPI application.</li>
		  <ul>
		    <li>Use your Heroku URL plus <span style='font-family: monospace;'>'/index.json'</span> as the URL to your Tropo app. Example: <span style='font-family: monospace;'>http://tropo-volunteer.heroku.com/index.json</span></li>
		  </ul>
        <li>There is no step four! Call in, use, and tinker with your app!
          <br /><br />If you make any tweaks to the application, you can use the following commands to send your changes up to Heroku. Then, call/IM your Tropo app again to hear your modified app!</li>
          <ul>
            <li><span style='font-family: monospace;'>git commit -a -m 'your commit message'</span></li>
            <li><span style='font-family: monospace;'>git push heroku</span></li>
          </ul>
      </ol>
  </body>
</html>
  "
end