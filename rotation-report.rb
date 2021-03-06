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

# rotation-report.rb -- automatically generate an end-of-shift report.
#
# Gathers information about incidents during a PagerDuty rotation, and
# reports on them.

require 'rubygems'
require 'bundler/setup'

require 'date'
require 'json'
require 'nokogiri'

require "#{File.dirname(__FILE__)}/lib/campfire"
require "#{File.dirname(__FILE__)}/lib/pagerduty"
require "#{File.dirname(__FILE__)}/lib/report"

INCIDENTS_PATH = '/api/beta/incidents?offset=0&limit=100&sort_by=created_on%3Adesc&status='
ALERTS_PATH    = '/reports/2011/3?filter=all&time_display=local'
ONE_DAY        = 60 * 60 * 24
ONE_WEEK       = ONE_DAY * 7

pagerduty = PagerDuty::Agent.new

#
# Parse the on-call list.
#
escalation   = PagerDuty::Escalation.new ARGV
dashboard    = pagerduty.fetch "/dashboard"
escalation.parse dashboard.body
target_level = escalation.label_for_level "1"

unless target_level
  puts "Couldn't find the top-level rotation on the Dashboard."
  exit(1)
end

#
# Derive the on-call schedule
#
current_start  = nil
current_end    = nil
previous_start = nil
previous_end   = nil

schedule_page = pagerduty.fetch "/schedule"
schedule_data = Nokogiri::HTML.parse schedule_page.body

schedule_data.css("table#schedule_index div.rotation_strip").each do |policy|
  title = policy.css("div.resource_labels > a").text

  if title == target_level
    rotation = policy.css("td.rotation_properties div table tr").each do |row|
      if row.css("td")[0].text =~ /On-call now/i
        current_start  = Chronic.parse(row.css("td span")[0].text)
        current_end    = Chronic.parse(row.css("td span")[1].text)

        # Shifts are either one day or one week (currently, at least).
        # For a week-long shift, we want the previous full week. For a day
        # shift, we want the same day of the week, one week ago. Either
        # way, we want the start and end to be a full week before the current
        # start and end.
        previous_start = current_start - ONE_WEEK
        previous_end   = current_end   - ONE_WEEK
      end
    end
  end
end

unless current_start and current_end and previous_start and previous_end
  puts "Couldn't find the rotation schedule for level #{target_level}."
  exit(2)
end

#
# Parse the incident data.
#

# TODO: need to get more incident data if there are more than 100 incidents
# in the report period.  Make offset = limit for second page.
incidents_json = pagerduty.fetch INCIDENTS_PATH
incidents_data = JSON.parse(incidents_json.body)
incidents      = Report::Summary.new current_start, current_end, previous_start, previous_end

incidents_data['incidents'].each do |incident|
  incidents << PagerDuty::Incident.new(incident)
end

unresolved = incidents.current_count {|incident| !incident.resolved? }
resolvers  = incidents.current_summary {|incident, summary| summary[incident.resolver] += 1 if incident.resolved? }
triggers   = incidents.current_summary {|incident, summary| summary[incident.trigger_name] += 1 }

#
# Parse the alert data.
#
alerts_html = pagerduty.fetch ALERTS_PATH
alerts_data = Nokogiri::HTML(alerts_html.body)
alerts      = Report::Summary.new current_start, current_end, previous_start, previous_end

alerts_data.css("table#monthly_report_tbl > tbody > tr").each do |row|
  alerts << PagerDuty::Alert.new(row.css("td.date").text, row.css("td.type").text, row.css("td.user").text)
end

sms_or_phone = alerts.current_summary {|alert, summary| summary[alert.user] += 1 if alert.phone_or_sms? }
email        = alerts.current_summary {|alert, summary| summary[alert.user] += 1 if alert.email? }

#
# Build up the report format.
#

# Header
report =  "Rotation report for #{current_start.strftime("%B %d")} - "
report << "#{current_end.strftime("%B %d")}:\n"

# Incident volume
report << "  #{incidents.current_count} incidents"
report << ", #{unresolved} unresolved" if unresolved > 0
report << " (#{incidents.pct_change})\n\n"

# Resolutions
report << "Resolutions:\n  "
resolver_report = resolvers.map do |name, count|
  important_levels = ["1", "2"]
  # TODO: make this a command-line option
  if important_levels.include? escalation.level_for_person(name) 
    "#{name} (#{escalation.label_for_person(name)}): #{count}"
  else
    "#{name}: #{count}"
  end
end
report << resolver_report.join(", ") + "\n"
report << "\n"

# Alert volume
report << "SMS/Phone Alerts "
report << "(#{alerts.current_count {|alert| alert.phone_or_sms? }} total, "
report << "#{alerts.pct_change {|alert| alert.phone_or_sms? }}; "
report << "#{alerts.current_count {|alert| alert.phone_or_sms? and alert.graveyard? }} after midnight, "
report << "#{alerts.pct_change {|alert| alert.phone_or_sms? and alert.graveyard? }}):\n  "
report << sms_or_phone.map {|name, count| "#{name}: #{count}"}.join(", ") + "\n"
report << "\n"

# Top triggers
report << "Top triggers:\n"
trigger_report = triggers.map do |trigger, count| 
  trigger_change = Report.pct_change(incidents.previous_count {|incident| incident.trigger_name == trigger }, count)
  "  #{count} \'#{trigger}\' (#{trigger_change})"
end
report << trigger_report.take(5).join("\n")
report << "\n"

#
# Report output
#

# TODO: add options.
#campfire = Campfire::Bot.new
#campfire.paste report

print report


