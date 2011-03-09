#!/usr/bin/env ruby

# Copyright 2011 Marc Hedlund <marc@precipice.org>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# oncall.rb -- find and list the people currently on call for PagerDuty.
#
# This scrapes a list of on-call assignments out of the PagerDuty Dashboard.
# You can specify which rotation levels you want to find, by giving one or
# more level numbers as arguments. If no arguments are given, all levels are
# reported.
#
# PagerDuty login cookies will be stored at ~/.pagerduty-cookies, so you
# should only need to enter login credentials on the first run.

require 'rubygems'
require 'bundler/setup'
require 'net/smtp'

require 'optparse'

require "#{File.dirname(__FILE__)}/lib/pagerduty"

# Look for reporting options
options = {}

optparse = OptionParser.new do |opts|
  opts.banner = "Usage: duty-email.rb\n" +
                "Send an email reminder to the on-call person (and any relevant CCs)."

  options[:smtp_server] = 'localhost'
  opts.on( '-m', '--smtp-server HOSTNAME', 'Use HOSTNAME as the SMTP server.') do |host|
    options[:smtp_server] = host
  end

  options[:subject] = 'you are now on pager duty'
  opts.on( '-s', '--subject SUBJECT', 'Use SUBJECT as the subject line of the email.') do |subject|
    options[:subject] = subject
  end

  options[:ccs] = []
  opts.on( '-c', '--cc EMAIL', 'Send a copy of the email to EMAIL.' ) do |cc|
    options[:ccs] << cc
  end

  opts.on( '-h', '--help', 'Display this message' ) do
    puts opts
    exit
  end
end

optparse.parse!

# Log into PagerDuty and get the Dashboard page.
pagerduty  = PagerDuty::Agent.new
escalation = PagerDuty::Escalation.new "1"
person = PagerDuty::Person.new
dashboard  = pagerduty.fetch "/dashboard"
levels     = escalation.parse dashboard.body

# Get the email address for each on-call level.
levels.each do |level|
  user = pagerduty.fetch level['person_path']
  person.parse user.body
  level['email'] = person.email
end

from = "noreply@change.org"
recips = options[:ccs] + (levels.map { |level| level['email'] })
to_line = levels.map{|level| "#{level['person']} <#{level['email']}>" }.join(", ")
cc_line = options[:ccs].join(", ")
message = <<MESSAGE_END
From: DO NOT REPLY <#{from}>
To: #{to_line}
CC: #{cc_line}
Subject: #{options[:subject]}

This email is to let you know that you are now on pager duty.  You will receive
phone calls for urgent issues, and you are asked to log in and handle any tasks
as necessary in the tech_ops Help Desk queue:

http://helpdesk.change.org

Thanks.

MESSAGE_END

#Net::SMTP.start(options[:smtp_server]) do |smtp|
  #smtp.send_message message, 'noreply@change.org', recips
#end
puts recips.join(',')
puts message

exit(0)
