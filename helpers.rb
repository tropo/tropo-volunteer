require 'time'

def shorten_url(long_url)
  short_url = open("http://tinyurl.com/api-create.php?url=#{long_url}").read.gsub(/https?:\/\//, "")
end

def readable_tinyurl(url)
  unique_url = url.split("/")[1].split(//).join(",")+","
  "tiny u r l dot com slash #{unique_url}"
end

def pretty_time(input)
  Time.parse(input).strftime("%a %m/%d at %I:%M %p")
end