%w(rubygems sinatra tropo-webapi-ruby pp open-uri json goodies.rb).each{|lib| require lib}
enable :sessions

post '/index.json' do
  v = Tropo::Generator.parse request.env["rack.input"].read
  session[:caller] = v[:session][:from][:id]
  t = Tropo::Generator.new
    t.on :event => 'error', :next => '/error.json'     # For fatal programming errors. Log some details so we can fix it
    t.on :event => 'hangup', :next => '/hangup.json'   # When a user hangs or call is done. We will want to log some details.
    t.on :event => 'continue', :next => '/next.json'
    t.say "Welcome to Do-Good-by-Phone."

    t.ask :name => 'zip', :bargein => true, :timeout => 7, :required => true, :attempts => 4,
        :say => [{:event => "timeout", :value => "Sorry, I did not hear anything."},
                 {:event => "nomatch:1 nomatch:2 nomatch:3", :value => "That wasn't a five-digit zip code."},
                 {:value => "In what zip code would you like to search for volunteer opportunities in?."}],
                  :choices => { :value => "[5 DIGITS]"}
  t.response
end

post '/next.json' do
  v = Tropo::Generator.parse request.env["rack.input"].read
  t = Tropo::Generator.new
    t.on  :event => 'error', :next => '/error.json'
    t.on  :event => 'hangup', :next => '/hangup.json'
    t.on  :event => 'continue', :next => '/say_page_of_tweets.json'
    t.say v[:result][:actions][:zip][:value]
    t.hangup
  t.response  
end

# post '/say_page_of_tweets.json' do
#   t = Tropo::Generator.new
#     t.on  :event => 'error', :next => '/error.json'  
#     t.on  :event => 'hangup', :next => '/hangup.json'
#     t.on  :event => 'continue', :next => '/say_page_of_tweets.json'
#     t.say "I'm about to read you the"
#     t.say say_as_ordinal(session[:page])
#     t.say " #{session[:count]} tweets by #{session[:user]}."
#     source = "http://twitter.com/statuses/user_timeline/#{session[:user]}.rss?count=#{session[:count]}&page=#{session[:page]}"
#     rss = REXML::Document.new(open(source).read).root
#     rss.root.elements.each("channel/item") { |element|
#       t.say "Tweet from about #{Time.parse(element.get_text('pubDate').to_s).to_pretty}"
#       t.say reformat_uris(element.get_text('title').to_s) + "," # comma for extra pause between tweets.
#     }
#     session[:page] += 1
#   t.response
# end

post '/hangup.json' do
  v = Tropo::Generator.parse request.env["rack.input"].read
  puts " Call complete. Call duration: #{v[:result][:call_duration]} second(s)"
  puts "  Caller info: ID=#{session[:caller][:id]}, Name=#{session[:caller][:name]}"
  puts "  Call logged in CDR. Tropo session ID: #{session[:id]}"
end

post '/error.json' do
  v = Tropo::Generator.parse request.env["rack.input"].read
  puts "!"*10 + "ERROR (see rack.input below); call ended"
  pp v # Print the JSON to our Sinatra console/log so we can find the error
end