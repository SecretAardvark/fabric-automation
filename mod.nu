# Resolve paths relative to this module so it can be used from any directory.
# NOTE: `path self` is parse-time only, so these must be `const`.
const YT_REVIEW_MODULE_DIR = (path self | path dirname)
const YT_REVIEW_FEEDS_FILE = ($YT_REVIEW_MODULE_DIR | path join "defaultFeeds.nu")

use $YT_REVIEW_FEEDS_FILE feeds

# Find the base directory for config/data files (where `.env` lives).
# Priority:
#   1) $env.YT_REVIEW_DIR (explicit override)
#   2) ~/.config/yt-review (global config)
#   3) module directory (repo default)
#   4) current working directory (optional per-project override)
def get_base_dir [] {
    let candidates = [
        ($env | get -o YT_REVIEW_DIR | default "")
        ("~/.config/yt-review" | path expand)
        $YT_REVIEW_MODULE_DIR
        ($env.PWD)
    ]

    for dir in $candidates {
        if ($dir | is-empty) { continue }
        let env_path = ($dir | path join ".env")
        if ($env_path | path exists) {
            return $dir
        }
    }

    # Last resort: fall back to module dir (gives a deterministic location)
    $YT_REVIEW_MODULE_DIR
}


# Load list of failed video URLs
def load_failed_urls [] {
    let failed_path = ($env | get -o FAILED_PATH | default "" | path expand)
    if ($failed_path | is-empty) or not ($failed_path | path exists) {
        []
    } else {
        open $failed_path | lines | uniq
    }
}

# Add a URL to the failed videos cache
def add_failed_url [url: string, reason: string] {
    let failed_path = ($env | get -o FAILED_PATH | default "" | path expand)
    if ($failed_path | is-empty) { return }

    # Create file if it doesn't exist
    if not ($failed_path | path exists) {
        touch $failed_path
    }

    # Append with timestamp and reason as comment
    let entry = $"($url) # ($reason) - (date now | format date '%Y-%m-%d')"
    let current = (open $failed_path)

    # Only add if not already present
    if not ($current | str contains $url) {
        $"($current)\n($entry)" | save -f $failed_path
        print $"(ansi yellow)Added to failed cache: ($url)(ansi reset)"
    }
}

# Check if URL is in the failed cache
def is_failed_url [url: string] {
    let failed_urls = (load_failed_urls)
    $failed_urls | any {|line| $line | str contains $url}
}

# Append a URL to videolist.txt so a mid-run crash doesn't leave it un-tracked.
# Replaces the previous behavior of bulk-saving all new URLs upfront.
def mark_url_processed [url: string] {
    let videoPath = ($env.VIDEO_PATH | path expand)
    $"\n($url)" | save --append $videoPath
}

def get_latest_urls [] {
    mut latestVideos: list<record> = []
    let videoPath = ($env.VIDEO_PATH | path expand)

    mut videoList = if ($videoPath | path exists ) {
        (open $videoPath | lines | uniq)
    } else {
        touch $videoPath
        []
    }

    for feed in $feeds {
        print $"(ansi blue)Checking ($feed.name)...(ansi reset)"
        try {
            let feed_videos = (parse_rss $feed.url)

            # Process each video from the feed (handles same-day multiple uploads)
            mut new_count = 0
            for video in $feed_videos {
                # Skip if in failed cache
                if (is_failed_url $video.url) {
                    continue
                }

                # Only append if URL is not in videoList
                if not ($videoList | any {|existing| $existing == $video.url }) {
                    $new_count = $new_count + 1
                    $videoList = ($videoList | append $video.url)
                    $latestVideos = ($latestVideos | append {
                        name: $feed.name,
                        url: $video.url
                    })
                }
            }

            if $new_count > 0 {
                if $new_count == 1 {
                    print $"(ansi green)New video found for ($feed.name)(ansi reset)"
                } else {
                    print $"(ansi green)($new_count) new videos found for ($feed.name)(ansi reset)"
                }
            }
        } catch {
            |e| print $"(ansi red)Error processing feed ($feed.name): ($e.msg)(ansi reset)"
            continue
        }
    }

    # NOTE: do not bulk-save here. URLs are appended one at a time in the main loop
    # via mark_url_processed, so a mid-run crash can't poison the next run's
    # "new videos" check by marking unprocessed URLs as already seen.
    if ($latestVideos | is-empty) {
        print $"(ansi yellow)No new videos found(ansi reset)"
        return null
    } else {
        $latestVideos
    }
}


# Function to fetch RSS feed content - returns list of {url, published} records
def parse_rss [url: string, --all (-a)] {
    try {
        let entries = http get $url
            | get content
            | where tag == entry

        # Extract url and published date from each entry
        let parsed = $entries | each {|entry|
            let content = $entry.content
            let video_url = ($content | where tag == link | get attributes.href | first)
            let published = ($content | where tag == published | get content | first | get content | first)
            { url: $video_url, published: $published }
        }

        if $all {
            $parsed
        } else {
            # Return only same-day videos (compared to the most recent video)
            if ($parsed | is-empty) { return [] }

            let today = (date now | format date '%Y-%m-%d')
            let same_day_videos = $parsed | where {|v|
                ($v.published | into datetime | format date '%Y-%m-%d') == $today
            }

            # If no videos from today, just return the most recent one
            if ($same_day_videos | is-empty) {
                $parsed | first 1
            } else {
                $same_day_videos
            }
        }
    } catch {
        |e| print $"(ansi red)Error parsing RSS feed ($url): ($e.msg)(ansi reset)"
        return []
    }
}

# Helper function to remove <think> blocks from fabric output
def clean_fabric_output [raw_output: string] {
    if ($raw_output | str contains "<think>") and ($raw_output | str contains "</think>") {
        let parts = ($raw_output | split row "</think>")
        if ($parts | length) > 1 {
            $parts | skip 1 | str join "" | str trim
        } else {
            $raw_output # Fallback if split didn't work as expected
        }
    } else {
        $raw_output # No think tags found
    }
}

# Helper to find matching closing brace for nested JSON
def find_matching_brace [text: string, start: int] {
    let chars = ($text | split chars)
    mut depth = 0
    mut pos = $start

    for char in ($chars | skip $start) {
        if $char == "{" { $depth = $depth + 1 }
        if $char == "}" {
            $depth = $depth - 1
            if $depth == 0 { return $pos }
        }
        $pos = $pos + 1
    }
    -1  # No matching brace found
}

# Helper function to safely parse JSON from fabric output
def parse_fabric_json [raw_output: string, url: string] {
    # Clean the output first
    let cleaned_output = (clean_fabric_output $raw_output)

    # Extract JSON from the cleaned output
    let json_string = if ($cleaned_output | str starts-with "{") and ($cleaned_output | str ends-with "}") {
        $cleaned_output
    } else {
        # Attempt to find JSON if it's embedded
        let start_index = ($cleaned_output | str index-of "{")

        if $start_index == -1 {
            print $"(ansi red)Error: Could not find JSON start marker in output for URL: ($url)(ansi reset)"
            return null
        }

        # Find the matching closing brace (handles nested objects)
        let end_index = (find_matching_brace $cleaned_output $start_index)

        if $end_index == -1 {
            print $"(ansi red)Error: Could not find matching closing brace for URL: ($url)(ansi reset)"
            return null
        }

        $cleaned_output | str substring $start_index..($end_index + 1)
    }

    # Check if json_string is actually a string
    if (($json_string | describe) !~ "string") {
        print $"(ansi red)Error: Potential JSON content is not a string type: ($json_string | describe)(ansi reset)"
        return null
    }

    try {
        let parsed_json = ($json_string | from json)
        return $parsed_json
    } catch {
        |e| print $"(ansi red)Error: Could not parse JSON from fabric output for URL: ($url): ($e.msg)(ansi reset)"
    #  print $"(ansi red)Raw output was: ($raw_output)(ansi reset)"
    #    print $"(ansi red)Cleaned output was: ($cleaned_output)(ansi reset)"
    #    print $"(ansi red)Attempted to parse: ($json_string)(ansi reset)"
        return null
    }
}

def get_fabric_rating [url: string, feed_name: string] {
    print $"(ansi blue)Getting fabric rating for ($feed_name): (ansi reset)($url)"

    mut transcript = null
    # Exponential backoff delays (in seconds)
    let delays = [2, 5, 10, 15]

    for attempt in 1..4 {
        if $attempt > 1 {
            let delay = ($delays | get ($attempt - 2))
            print $"(ansi yellow)Waiting ($delay) seconds before retry attempt ($attempt)/4..(ansi reset)"
            sleep ($delay * 1sec)
        }

        let result = try {
            # Add a small random delay to avoid hitting rate limits in parallel processing
            sleep ((random int 1..3) * 1sec)
            # Hard timeout (180s) so a hung fabric/yt-dlp can't deadlock the run.
            # --kill-after sends SIGKILL 10s after SIGTERM if the child ignores it.
            ^timeout --kill-after=10 180 fabric --disable-responses-api -y $url
        } catch {
            |e|
            let error_msg = ($e.msg | default "Unknown error")
            let exit_code = ($e | get -o exit_code | default "unknown")

            # GNU timeout exits 124 when it had to kill the child. Retrying the same
            # hang is pointless — mark the URL failed and bail.
            if ($exit_code == 124) {
                print $"(ansi red)Timed out fetching transcript for ($feed_name) - (ansi reset)($url)"
                add_failed_url $url "Timeout fetching transcript"
                return null
            }

            if $attempt < 4 {
                print $"(ansi yellow)Error getting transcript attempt ($attempt)/4: ($error_msg) Exit code: ($exit_code)(ansi reset)"

                # Check for specific error types and handle differently
                if ($error_msg | str contains "rate limit") or ($error_msg | str contains "429") {
                    print $"(ansi yellow)Rate limit detected, increasing delay...(ansi reset)"
                    sleep 30sec  # Longer delay for rate limits
                } else if ($error_msg | str contains "network") or ($error_msg | str contains "timeout") {
                    print $"(ansi yellow)Network issue detected, retrying...(ansi reset)"
                } else if ($error_msg | str contains "Private video") or ($error_msg | str contains "Video unavailable") or ($error_msg | str contains "members-only") {
                    print $"(ansi red)Video is private or unavailable for ($feed_name) - (ansi reset)($url)"
                    add_failed_url $url "Private/Unavailable"
                    return null  # Don't retry for these errors
                } else if ($error_msg | str contains "age-restricted") or ($error_msg | str contains "Sign in to confirm") {
                    print $"(ansi red)Video is age-restricted for ($feed_name) - (ansi reset)($url)"
                    add_failed_url $url "Age-restricted"
                    return null
                }
                null
            } else {
                print $"(ansi red)Error getting transcript for ($feed_name) - (ansi reset)($url): (ansi red)($error_msg) Exit code: ($exit_code)(ansi reset)"
                add_failed_url $url "Transcript retries exhausted"
                return null
            }
        }
   
        if $result != null and not ($result | is-empty) {
            $transcript = $result
            print $"(ansi green)Successfully got transcript for ($feed_name) (ansi reset)on attempt ($attempt) 👍"
            break
        }
    }

    if $transcript == null {
        return null
    }

    if ($transcript | is-empty) {
        print $"(ansi red)Error: Empty transcript returned for ($feed_name) - (ansi reset)($url)"
        return null
    }

    # Add delay before rating to avoid overwhelming the API
    sleep 2sec

    # Get rating with error handling and retry
    mut raw_output = ""
    for rating_attempt in 1..3 {
        let result = try {
            $transcript | ^timeout --kill-after=10 120 fabric --disable-responses-api -p tag_and_rate
        } catch {
            |e|
            let exit_code = ($e | get -o exit_code | default "unknown")
            if ($exit_code == 124) {
                print $"(ansi red)Timed out getting rating for ($feed_name) - (ansi reset)($url)"
                add_failed_url $url "Timeout getting rating"
                return null
            }
            if $rating_attempt < 3 {
                print $"(ansi yellow)Error getting rating attempt ($rating_attempt)/3, retrying...(ansi reset)"
                null
            } else {
                print $"(ansi red)Error getting rating for ($feed_name) - (ansi reset)($url): (ansi red) ($e.msg)(ansi reset)"
                add_failed_url $url "Rating retries exhausted"
                null
            }
        }

        if $result != null and not ($result | is-empty) {
            $raw_output = $result
            break
        }
    }

    if $raw_output == null {
        return null
    }


    # Check if we got any output at all
    if ($raw_output | is-empty) {
        print $"(ansi red)Error: No output received from fabric for URL: ($url)(ansi reset)"
        return null
    }

    let rating_data = (parse_fabric_json $raw_output $url)

    # Check if the result is a record
    if ($rating_data | describe) =~ "^record" {
        # Add the feed name and url to the rating record
        { ...$rating_data, name: $feed_name, url: $url, transcript: $transcript }
    } else {
        print $"(ansi red)Error: Parsed JSON is not a record for URL: (ansi reset)($url)"
        print $"(ansi red)Parsed content type: (ansi reset)($rating_data | describe)"
        print $"(ansi red)Parsed content: (ansi reset)($rating_data)"
        return null
    }
}

# Helper function to ensure the review directory exists
def ensure_review_directory [] {
    let vault_dir = ($"($env.VAULT_PATH)/(date now | format date '%m-%d-%Y')" | path expand)
    # Expand the path to resolve the tilde
    #let expanded_vault_dir = ($vault_dir | path expand)

    # Check if directory exists and create if not
    if not ($vault_dir | path exists) {
        try {
            mkdir $vault_dir
            print $"(ansi green)Created directory: ($vault_dir)(ansi reset)"
        } catch {
            |e| print $"(ansi red)Error: (ansi reset) Failed to create directory ($vault_dir): (ansi red) ($e.msg)(ansi reset)"
            return null # Indicate failure
        }
    }
    $vault_dir # Return the path
}

# Helper function to execute the main fabric review command
def execute_fabric_review [url: string, prompt: string, transcript: string] {
    print $'(ansi blue)Analyzing video with prompt: (ansi reset) ($prompt)'
    #print "Running fabric command..."

    try {
        let cmd_result = ($transcript | ^timeout --kill-after=10 240 fabric --disable-responses-api $prompt)

        # Clean the output using the helper function
        clean_fabric_output $cmd_result

    } catch {
        |e| match ($e | is-empty) {
            true => {
                print $"(ansi yellow)Fabric command returned empty output(ansi reset)"
                return ""
            }
            false => {
                let exit_code = ($e | get -o exit_code | default "unknown")
                if ($exit_code == 124) {
                    print $"(ansi red)Timed out running fabric review for: (ansi reset)($url)"
                    return null
                }
                match true {
                    ($e.msg | str contains "invalid YouTube URL, can't get video ID") => {
                        print $"(ansi red)Invalid YouTube URL: (ansi reset)($url)"
                        return null
                    }
                    ($e.msg | str contains "transcript not available. (EOF)") => {
                        print $"(ansi yellow)No transcript found for (ansi reset)($url)"
                        return null
                    }
                    _ => {
                        print $"(ansi red)Error running fabric command: (ansi reset)($e.msg)"
                        return null # Indicate failure
                    }
                }
            }
        }
    }
}

# Helper function to format and save the review file
def format_and_save_review [
    file_path: string,
    review_content: string,
    rating_data: record
] {
    let safe_title = ($rating_data | get -o suggested-title | default "Review" | str trim)
    let safe_name = ($rating_data | get -o name | default "Unknown" | str trim)

    # Process labels and suggested tags
    let labels = ($rating_data | get -o labels | default "" | split row "," | each {|label| $"[[($label | str trim)]]"} | str join " ")
    let suggested_tags = ($rating_data | get -o suggested-tags | default "" | split row "," | each {|tag| $"[[($tag | str trim)]]"} | str join " ")

    let all_labels = ([$labels, $suggested_tags] | str join " " | str trim)
    let labels_array = ($all_labels | split row " ")
    let hashtag_labels = ($labels_array | where {|it| not ($it | is-empty)} | each {|label|
        $"#(($label | str replace -a '[[' '' | str replace -a ']]' ''))"
    })

    let header = [
        $"([[$safe_name]])",
        #$"Tags: ($hashtag_labels | str join ' ')",
        $"***[($safe_title)]\(($rating_data.url)\)***\n",

        $"Rating: ($rating_data.rating | default 'N/A') Analysed with **($rating_data.'suggested-prompt' | default 'N/A')** \n",

        $"***($rating_data.'one-sentence-summary' | default '')***\n",
    ]

    # Combine header and review content
    let final_content = ($header | append $"($review_content)\n" | append $"($hashtag_labels | str join ' ')\n") | append $"($all_labels)\n"

    # Save the file
    try {
        $final_content | save -f $file_path
        print $"(ansi green)File successfully saved: (ansi reset)($file_path)"
        return true # Indicate success
    } catch {
        |e| print $"(ansi red)Error saving file (ansi reset)($file_path): (ansi red) ($e.msg)(ansi reset)"
        return false # Indicate failure
    }
}

def review_url [url: string, rating: record] {
    # --- 1. Check Rating ---
    let rating_value_str = ($rating | get -o rating | default "D" | into string)
    let rating_letter = (extract_rating_letter $rating_value_str)

    # Skip only D tier (and below if any). Process S, A, B, C tiers
    let should_skip = ($rating_letter in ["D"])
    
    print $"(ansi blue)Rating: (ansi reset)($rating_letter) Tier - ($rating.one-sentence-summary)"
    if $should_skip {
        print $"(ansi yellow)Rating too low (($rating_letter)). Skipping review.(ansi reset)"
        return
    }

    # --- 2. Ensure Directory and Change To It ---
    let target_dir = (ensure_review_directory)


    # Store current directory to return to it later
    let original_dir = (pwd)

    # Change to the directory
    try {
        cd $target_dir
        # print $"Changed directory to: (pwd)" # Optional: uncomment for debugging
    } catch {
        |e| print $"(ansi red)Error: (ansi reset) Failed to change directory to ($target_dir): (ansi red) ($e.msg)(ansi reset)"
        return # Cannot proceed without correct directory
    }

    # --- 3. Prepare Filename ---
    let safe_title = ($rating | get -o suggested-title | default "Review" | str trim)
    let safe_name = ($rating | get -o name | default "Unknown" | str trim)
    let review_filename = $'($safe_title) - ($safe_name) (date now | format date "%m-%d-%Y").md'
    let review_filepath = ($target_dir | path join $review_filename) # Use full path

    # --- 4. Execute Fabric Review ---
    let review_content = (execute_fabric_review $url ($rating | get -o 'suggested-prompt' | default 'Summarize this video') $rating.transcript)

    if $review_content == null {
        print $"(ansi red)Fabric review command failed. Aborting file save.(ansi reset)"
        cd $original_dir # Return to original directory on failure
        return
    }

    if ($review_content | is-empty) {
        print $"(ansi yellow)Fabric review resulted in empty content. Saving header only.(ansi reset)"
    } else {
        print $"(ansi green)Fabric review completed. 👍(ansi reset)"
    }

    # --- 5. Format and Save File ---
    let save_success = (format_and_save_review $review_filepath $review_content $rating)

    # --- 6. Return to Original Directory ---
    cd $original_dir
    # print $"Returned to directory: (pwd)" # Optional: uncomment for debugging

    if not $save_success {
        print $"(ansi red)Failed to save the review file.(ansi reset)"
        # Potentially add more cleanup or error reporting here
    }
}


def extract_video_id [url: string] {
    try {
        $url | parse --regex 'v=(?P<id>[^&?#]+)' | get id.0
    } catch {
        try {
            $url | parse --regex 'youtu\.be/(?P<id>[^?&/#]+)' | get id.0
        } catch {
            try {
                $url | parse --regex '/embed/(?P<id>[^?&/#]+)' | get id.0
            } catch {
                try {
                    $url | parse --regex '/shorts/(?P<id>[^?&/#]+)' | get id.0
                } catch {
                    null
                }
            }
        }
    }
}

def build_playlist_url [urls: list<string>] {
    let ids = ($urls | each {|u| extract_video_id $u } | where $it != null)
    if ($ids | is-empty) { null } else { $"https://www.youtube.com/watch_videos?video_ids=($ids | str join ',')" }
}

# Extract rating letter (S/A/B/C/D) from rating string
def extract_rating_letter [rating_str: string] {
    $rating_str | split row " " | first | str trim
}

# Print end-of-run statistics
def print_stats [stats: record] {
    let total = $stats.s + $stats.a + $stats.b + $stats.c + $stats.d + $stats.skipped + $stats.failed
    if $total == 0 { return }

    print ""
    print $"(ansi blue)═══════════════════════════════════════(ansi reset)"
    print $"(ansi blue)           Run Statistics(ansi reset)"
    print $"(ansi blue)═══════════════════════════════════════(ansi reset)"

    if $stats.s > 0 { print $"  (ansi green)S-Tier:(ansi reset)  ($stats.s) - must watch" }
    if $stats.a > 0 { print $"  (ansi green)A-Tier:(ansi reset)  ($stats.a) - highly recommended" }
    if $stats.b > 0 { print $"  (ansi cyan)B-Tier:(ansi reset)  ($stats.b) - worth watching" }
    if $stats.c > 0 { print $"  (ansi yellow)C-Tier:(ansi reset)  ($stats.c) - if you have time" }
    if $stats.d > 0 { print $"  (ansi white)D-Tier:(ansi reset)  ($stats.d) - skipped" }
    if $stats.failed > 0 { print $"  (ansi red)Failed:(ansi reset)  ($stats.failed)" }

    let reviewed = $stats.s + $stats.a + $stats.b + $stats.c
    print $"(ansi blue)───────────────────────────────────────(ansi reset)"
    print $"  (ansi white)Total:(ansi reset)   ($total) videos processed"
    print $"  (ansi white)Reviewed:(ansi reset) ($reviewed) | (ansi white)Skipped:(ansi reset) ($stats.d + $stats.failed)"
    print $"(ansi blue)═══════════════════════════════════════(ansi reset)"
}

# Cross-platform URL opener with omarchy fallback
def open_url [url: string, app_name: string = ""] {
    # Try omarchy first (if available)
    if $app_name != "" {
        let omarchy_result = try {
            ^omarchy-launch-or-focus-webapp $app_name $url
            true
        } catch {
            false
        }
        if $omarchy_result { return }
    }

    # Cross-platform fallback
    let os = ($nu.os-info.name | str downcase)
    try {
        match $os {
            "linux" => { ^xdg-open $url }
            "macos" => { ^open $url }
            "windows" => { ^cmd /c start $url }
            _ => { ^xdg-open $url }  # Default to xdg-open
        }
    } catch {
        |e| print $"(ansi yellow)Could not open URL automatically: (ansi reset)($url)"
        print $"(ansi yellow)Error: ($e.msg)(ansi reset)"
    }
}

def create_summary_page [
    items: list<record>,
    playlist_url: string
] {
    if ($items | is-empty) {
        return null
    }

    let target_dir = (ensure_review_directory)
    let date_str = (date now | format date '%m-%d-%Y')
    let file_path = ($target_dir | path join $'Summary - ($date_str).md')

    let header = [
        $"# YouTube Reviews Summary - ($date_str)\n",
        (if $playlist_url != null { $"*Playlist \(B or above\):* [Open in YouTube]\(($playlist_url)\)\n\n" } else { "" }),
        "---\n"
    ]

    let body = ($items | each {|it|
        let rating_value_str = ($it | get -o rating | default "D" | into string)
        let letter = (extract_rating_letter $rating_value_str)
        let title = ($it | get -o 'suggested-title' | default "Untitled" | str trim)
        let summary = ($it | get -o 'one-sentence-summary' | default "" | str trim)
        let url = ($it | get -o url | default "" | str trim)
        let channel = ($it | get -o name | default "" | str trim)
        $"- **($letter)** [($title)]\(($url)\) — ($summary) \(by ($channel)\)\n"
    } | str join "")

    let content = ($header | append $body) | str join ""

    try {
        $content | save -f $file_path
        print $"(ansi green)Summary saved: (ansi reset)($file_path)"
        $file_path
    } catch {
        |e| print $"(ansi red)Error saving summary: (ansi reset)($e.msg)"
        null
    }
}

def fetch-channel-id [channel_url: string] {
    try {
        http get $channel_url
        | to text
        | parse --regex '<link[^>]*?href="(https://www.youtube.com/channel/[^"]+)"[^>]*?>'
        | get capture0.0 # Get the first capture group value directly
    } catch {
        |e| print $"(ansi red)Error fetching/parsing channel ID for ($channel_url): ($e.msg)(ansi reset)"
        return null
    }
}

# View or clear the failed videos cache
export def "failed-videos" [
    --clear (-c)  # Clear the failed videos cache
] {
    let base_dir = (get_base_dir)
    if ($env | get -o FAILED_PATH | default "" | is-empty) {
        open ($base_dir | path join ".env") | from toml | load-env
    }

    let failed_path = ($env | get -o FAILED_PATH | default "" | path expand)

    if $clear {
        if ($failed_path | path exists) {
            rm $failed_path
            print $"(ansi green)Failed videos cache cleared.(ansi reset)"
        } else {
            print $"(ansi yellow)No failed videos cache to clear.(ansi reset)"
        }
        return
    }

    if not ($failed_path | path exists) {
        print $"(ansi yellow)No failed videos cached.(ansi reset)"
        return
    }

    let failed = (open $failed_path | lines | where {|l| not ($l | is-empty)})
    if ($failed | is-empty) {
        print $"(ansi yellow)No failed videos cached.(ansi reset)"
        return
    }

    let count = ($failed | length)
    print $"(ansi blue)Failed Videos Cache - ($count) entries:(ansi reset)"
    print ""
    $failed | each {|line|
        let parts = ($line | split row " # ")
        let url = ($parts | first)
        let reason = if ($parts | length) > 1 { $parts | skip 1 | str join " # " } else { "Unknown" }
        print $"  (ansi red)✗(ansi reset) ($url)"
        print $"    (ansi white)($reason)(ansi reset)"
    }
    null
}

# List all subscribed channels
export def "list-channels" [] {
    let count = ($feeds | length)
    print $"(ansi blue)Subscribed Channels - ($count) total:(ansi reset)"
    print ""

    $feeds | enumerate | each {|item|
        let idx = $item.index + 1
        let feed = $item.item
        let name = ($feed.name | str trim)
        let channel_id = ($feed.url | parse --regex 'channel_id=(.+)' | get capture0.0? | default "unknown")
        print $"  (ansi cyan)($idx | fill -a right -w 2).(ansi reset) ($name)"
        print $"      (ansi white)https://youtube.com/channel/($channel_id)(ansi reset)"
    }
    null
}

# Remove a channel by name or index
export def "remove-channel" [
    identifier: string  # Channel name (partial match) or index number from list-channels
] {
    let base_dir = (get_base_dir)
    if ($env | get -o VIDEO_PATH | default "" | is-empty) {
        open ($base_dir | path join ".env") | from toml | load-env
    }

    let feeds_file_path = ($base_dir | path join "defaultFeeds.nu")

    # Check if identifier is a number (index)
    let is_index = ($identifier | str trim | parse --regex '^\d+$' | is-not-empty)

    let channel_to_remove = if $is_index {
        let idx = ($identifier | into int) - 1
        if $idx < 0 or $idx >= ($feeds | length) {
            print $"(ansi red)Error: Index ($identifier) out of range. Use list-channels to see valid indices.(ansi reset)"
            return
        }
        $feeds | get $idx
    } else {
        # Find by partial name match (case-insensitive)
        let matches = $feeds | where {|f| ($f.name | str downcase) =~ ($identifier | str downcase)}
        if ($matches | is-empty) {
            print $"(ansi red)Error: No channel found matching '($identifier)'(ansi reset)"
            return
        }
        if ($matches | length) > 1 {
            print $"(ansi yellow)Multiple channels match '($identifier)':(ansi reset)"
            $matches | each {|m| print $"  - ($m.name | str trim)"}
            print $"(ansi yellow)Please be more specific or use the index number.(ansi reset)"
            return
        }
        $matches | first
    }

    let channel_name = ($channel_to_remove.name | str trim)
    print $"(ansi blue)Removing channel: (ansi reset)($channel_name)"

    try {
        let original_content = (open $feeds_file_path | into string)

        # Build regex pattern to match the channel entry
        # Match the entire block: { name: "...", url: "..." },
        let escaped_name = ($channel_to_remove.name | str replace -a '"' '\\"')
        let escaped_url = ($channel_to_remove.url | str replace -a '?' '\\?')

        # Find and remove the entry - match the block structure
        let pattern = $'\\{[\\s\\n]*name:\\s*"($escaped_name)"[\\s\\n]*url:\\s*"($escaped_url)"[\\s\\n]*\\},?'

        let modified_content = ($original_content | str replace --regex $pattern "")

        # Clean up any double newlines that might result
        let cleaned_content = ($modified_content | str replace --regex '\n{3,}' "\n\n")

        $cleaned_content | save -f $feeds_file_path
        print $"(ansi green)Successfully removed '($channel_name)' from feeds.(ansi reset)"
        print $"(ansi yellow)Note: Restart nushell or re-source the module to see changes.(ansi reset)"

    } catch {
        |e| print $"(ansi red)Error removing channel: ($e.msg)(ansi reset)"
    }
}

# New exported function to add a channel
export def "add-channel" [
    channel_url: string, # The URL of the channel page (e.g., https://www.youtube.com/@SomeChannel)
    name: string         # The desired name for the channel in the feed list
] {
    # Load env if not already loaded
    let base_dir = (get_base_dir)
    if ($env | get -o VIDEO_PATH | default "" | is-empty) {
        open ($base_dir | path join ".env") | from toml | load-env
    }

    print $"(ansi blue)Attempting to add channel: (ansi reset)($name) with URL:($channel_url)"

    # 1. Get Channel ID
    let channel = (fetch-channel-id $channel_url)
    let index = ($channel | str index-of "channel/")
    let channel_id = $channel | str substring ($index + 8)..-1

    if $channel_id == null {
        print $"(ansi red)Failed to retrieve channel ID. Aborting add operation.(ansi reset)"
        return
    }
    print $"(ansi green)Successfully retrieved Channel ID: (ansi reset)($channel_id)"

    # 2. Construct Feed URL and New Entry String
    let new_feed_url = $"https://www.youtube.com/feeds/videos.xml?channel_id=($channel_id)"
    # Ensure proper indentation and trailing comma for insertion
    let new_entry_string = $"\n    {\n        name: \" ($name | str trim)\"\n        url: \"($new_feed_url)\"\n    },"

    # 3. Read, Modify, and Save defaultFeeds.nu
    let feeds_file_path = ($base_dir | path join "defaultFeeds.nu")

    try {
        # Read the entire file content as a single string
        let original_content = (open $feeds_file_path | into string)

        # Find the index of the *last* closing bracket ']'
        let insertion_point = ($original_content | str index-of ']')

        if $insertion_point == null {
            print $"(ansi red)Error: Could not find the closing ']' in ($feeds_file_path). Cannot add new feed.(ansi reset)"
            return
        }

        # Get the part of the string *before* the last ']'
        let content_before_bracket = ($original_content | str substring 0..($insertion_point - 1))

        # Construct the modified content by inserting the new entry before the final ']'
        # Add a newline before the final ']' for better formatting.
        let modified_content = $"($content_before_bracket)($new_entry_string)\n]"

        # Save the modified content, overwriting the original file
        $modified_content | save -f $feeds_file_path
        print $"(ansi green)Successfully added channel '($name)' to (ansi reset)($feeds_file_path)."

    } catch {
        |e| print $"(ansi red)Error processing (ansi reset)($feeds_file_path): (ansi red) ($e.msg) ($e)(ansi reset)"
    }
}

# Main function to check feeds
export def main [...args: string] {
    let base_dir = (get_base_dir)
    open ($base_dir | path join ".env") | from toml | load-env

    #Check to see if the env variables are set.
    #print $env.VIDEO_PATH
    #print $env.VAULT_PATH
    if not ($args | is-empty) {
        let url = $args.0
        let name = if ($args | length) > 1 { $args.1 } else { "" }
        print $"(ansi blue)Processing URL from args: (ansi reset)($url)"
        let rating = get_fabric_rating $url $name
        if $rating != null {
            review_url $url $rating
        }
        return
    }

    # let input = $in | str split " "
    # if not ($input | is-empty) {
    #     let name = if (($input | str split " " | length) > 1) { $input | str split " " | last } else { "" }
    #     print $"Processing URL from pipe: ($input.0)"
    #     let rating = get_fabric_rating $input.0 $name
    #     if $rating != null {
    #         review_url $input.0 $rating
    #     }
    #     return
    # }

    print $"(ansi blue)No URL provided, checking feeds...(ansi reset)"
    let latest_urls = get_latest_urls
    mut playlist = []
    mut summary_items = []
    mut summary_urls = []
    mut stats = { s: 0, a: 0, b: 0, c: 0, d: 0, skipped: 0, failed: 0 }

    if $latest_urls != null {
        let total_videos = ($latest_urls | length)
        print $"(ansi blue)Found ($total_videos) new videos to process(ansi reset)"
        mut video_num = 0
        for link in $latest_urls {
            $video_num = ($video_num + 1)
            print $"(ansi blue)Processing video ($video_num)/($total_videos): ($link.name)(ansi reset)"

            # Guard the whole per-video pipeline so one bad video can't kill the run
            # before reaching create_summary_page / print_stats below.
            # Catch closures can't mutate outer mut vars, so capture the error and
            # handle it after the try block.
            let caught = try {
                let rating = get_fabric_rating $link.url $link.name

                if $rating != null {
                    # Extract rating letter for playlist decision
                    let rating_value_str = ($rating | get -o rating | default "D" | into string)
                    let rating_letter = (extract_rating_letter $rating_value_str)

                    # Track stats
                    match $rating_letter {
                        "S" => { $stats.s = $stats.s + 1 }
                        "A" => { $stats.a = $stats.a + 1 }
                        "B" => { $stats.b = $stats.b + 1 }
                        "C" => { $stats.c = $stats.c + 1 }
                        "D" => { $stats.d = $stats.d + 1 }
                        _ => { $stats.skipped = $stats.skipped + 1 }
                    }

                    # Add S and A tier videos to playlist
                    if ($rating_letter in ['S', 'A']) {
                        $playlist = $playlist | append $link.url
                    }

                    # Collect B or above for summary and playlist link
                    if ($rating_letter in ['S', 'A', 'B']) {
                        $summary_urls = ($summary_urls | append $link.url)
                        $summary_items = ($summary_items | append $rating)
                    }

                    review_url $link.url $rating

                } else {
                    print $"(ansi red)Failed to get rating for ($link.name) (ansi reset)($link.url)"
                    "rating_null"
                }
                null
            } catch {|e|
                {msg: ($e.msg | default "unknown"), name: $link.name}
            }

            if ($caught | describe) =~ "^record" {
                $stats.failed = $stats.failed + 1
                print $"(ansi red)Unexpected error processing ($caught.name): ($caught.msg)(ansi reset)"
            } else if $caught == "rating_null" {
                $stats.failed = $stats.failed + 1
            }

            # Always mark URL as processed (success or failure) so a later crash
            # doesn't leave it un-tracked, and so re-runs don't replay the same URL.
            mark_url_processed $link.url

            # Add delay between processing different videos to avoid rate limiting
            if $video_num < $total_videos {
                # print $"(ansi blue)Waiting 2 seconds before processing next video...(ansi reset)"
                sleep 2sec
            }
        }
    # Build and save summary page for B or above
    let summary_playlist_url = (build_playlist_url $summary_urls)
    create_summary_page $summary_items $summary_playlist_url

    if not ($playlist | is-empty) {
      let playlist_url = (build_playlist_url $playlist)
      if $playlist_url != null {
        open_url $playlist_url "YouTube"
      }
    }

    print_stats $stats
    } else {
        print $"(ansi yellow)No new videos found(ansi reset)"
    }
}


#7/6/24 cut the sleep timers down to 2 seconds to speed up the review process a bit.
#TODO: a function to just add labels/tags to files that already exist.
#TODO: parallel video processing with par-each for better performance


