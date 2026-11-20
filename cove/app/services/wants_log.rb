require "json"

# The relay's build list, written by need.
#
# Every fact the Manager wanted and could not get is appended here once, with
# the reason it could not be got. This file *is* the relay's API: when a want's
# count stops climbing, the relay has grown that function.
#
# Append-only JSONL: one JSON object per line, never rewritten, never sorted.
# The UI aggregates on read. (A year of this file is a few megabytes; when it
# isn't, that is the moment to add rotation, not before.)
module WantsLog
  class << self
    def record(want:, agent:, reason:)
      line = JSON.generate(
        "at" => Time.now.utc.iso8601,
        "want" => want.to_s,
        "agent" => agent.to_s,
        "reason" => reason.to_s
      )
      File.open(Cove.wants_file, "ab") do |f|
        f.flock(File::LOCK_EX)
        f.write(line + "\n")
      end
      line
    end

    # Every want, aggregated: the relay's build list as the UI shows it.
    # Sorted by most recently wanted first.
    def summary
      return [] unless File.exist?(Cove.wants_file)
      rows = {}
      File.foreach(Cove.wants_file) do |line|
        line = line.strip
        next if line.empty?
        begin
          rec = JSON.parse(line)
        rescue JSON::ParserError
          next
        end
        key = [rec["want"], rec["agent"]]
        row = rows[key] ||= {
          "want" => rec["want"], "agent" => rec["agent"],
          "count" => 0, "first_seen" => rec["at"], "last_seen" => rec["at"],
          "reason" => rec["reason"]
        }
        row["count"] += 1
        row["last_seen"] = rec["at"]
        row["reason"] = rec["reason"]
      end
      rows.values.sort_by { |r| r["last_seen"] }.reverse
    end

    def distinct_wants
      summary.map { |r| r["want"] }.uniq.sort
    end
  end
end
