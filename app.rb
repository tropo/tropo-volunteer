%w(rubygems sinatra tropo-webapi-ruby open-uri json/pure helpers.rb).each{|lib| require lib}

enable :sessions

post '/index.json' do
  v = Tropo::Generator.parse request.env["rack.input"].read
  session[:caller] = v[:session][:from][:id]
  t = Tropo::Generator.new(:voice => "kate")
    t.on :event => 'error', :next => '/error.json'     # For fatal programming errors. Log some details so we can fix it
    t.on :event => 'hangup', :next => '/hangup.json'   # When a user hangs or call is done. We will want to log some details.
    t.on :event => 'continue', :next => '/process_zip.json'
    t.say "Well hello there."

    t.ask :name => 'zip', :bargein => true, :timeout => 7, :required => true, :attempts => 4,
        :say => [{:event => "timeout", :value => "Sorry, I did not hear anything."},
                 {:event => "nomatch:1 nomatch:2 nomatch:3", :value => "That wasn't a five-digit zip code."},
                 {:value => "In what zip code would you like to search for volunteer opportunities in?."}],
                  :choices => { :value => "[5 DIGITS]"}
  t.response
end

post '/process_zip.json' do
  v = Tropo::Generator.parse request.env["rack.input"].read
  t = Tropo::Generator.new(:voice => "kate")
    t.on  :event => 'error', :next => '/error.json'
    t.on  :event => 'hangup', :next => '/hangup.json'
    t.on  :event => 'continue', :next => '/process_input.json'
    t.say v[:result][:actions][:zip][:value]
    params = {
      :num => "10",
      :output => "json",
      :vol_loc => v[:result][:actions][:zip][:value].gsub(" ",""),
      :vol_startdate => Time.now.strftime("%Y-%m-%d"),
      :vol_enddate => (Time.now+604800).strftime("%Y-%m-%d")
      }
      
    url = "http://www.allforgood.org/api/volopps?key=tropo"
    params.each{|key,value| url << "&#{key}=#{value}"}
    t.say(url)
    begin
      data = JSON.parse(open(url).read)
      puts data
      t.say "#{data["items"].size} opportunities found. I'll read them to you"
    rescue => e
      puts e # print error to sinatra console
      t.say "It looks like something went wrong with our data source. Please try again later. "
      t.hangup
    end
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
  puts v.inspect
end