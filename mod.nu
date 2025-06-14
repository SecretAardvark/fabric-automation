use defaultFeeds.nu



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
            let feed_url = (parse_rss $feed.url | first)
            # Only append if URL is not in videoList
            if not ($videoList | any {|existing| $existing == $feed_url }) {
                print $"(ansi green)New video found for ($feed.name)(ansi reset)"
                $videoList = ($videoList | append $feed_url)
                $latestVideos = ($latestVideos | append {
                    name: $feed.name,
                    url: $feed_url
                })
            }
        } catch {
            |e| print $"(ansi red)Error processing feed ($feed.name): ($e.msg)(ansi reset)"
            continue
        }
    }

    # Save unique entries only
    $videoList | uniq | save $videoPath -f
    if ($latestVideos | is-empty) {
        print $"(ansi yellow)No new videos found(ansi reset)"
        return null
    } else {
        $latestVideos
    }
}


# Function to fetch RSS feed content
def parse_rss [url: string] {
    try {
        http get $url
        | get content
        | where tag == entry
        | first
        | get content
        | where tag == link
        | get attributes
        | get href
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
        let end_index = ($cleaned_output | str index-of "}")

        if $start_index != -1 and $end_index != -1 {
            $cleaned_output | str substring $start_index..($end_index + 1)
        } else {
            print $"(ansi red)Error: Could not find valid JSON markers in cleaned output for URL: ($url)(ansi reset)"
            print $"(ansi red)Cleaned output was: ($cleaned_output)(ansi reset)"
            return null
        }
    }

    #print $"JSON String: ($json_string)" # Optional: uncomment for debugging

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
        print $"(ansi red)Raw output was: ($raw_output)(ansi reset)"
        print $"(ansi red)Cleaned output was: ($cleaned_output)(ansi reset)"
        print $"(ansi red)Attempted to parse: ($json_string)(ansi reset)"
        return null
    }
}

def get_fabric_rating [url: string, feed_name: string] {
    print $"(ansi blue)Getting fabric rating for ($feed_name): (ansi reset)($url)"
    
    mut transcript = null
    for attempt in 1..4 {
        let result = try {
            fabric -y $url
        } catch {
            |e| 
            if $attempt < 3 {
                print $"(ansi yellow)Error getting transcript attempt ($attempt)/3, retrying...(ansi reset)"
                null
            } else {
                print $"(ansi red)Error getting transcript for ($feed_name) - (ansi reset)($url): (ansi red) ($e.msg)(ansi reset)"
                print $"(ansi red)Failed to get transcript after 3 attempts. Aborting.(ansi reset)"
                null
            }
        }
        
        if $result != null {
            $transcript = $result
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
    
    # Get rating with error handling
    let raw_output = try {
        $transcript | fabric -p tag_and_rate
    } catch {
        |e| print $"(ansi red)Error getting rating for ($feed_name) - (ansi reset)($url): (ansi red) ($e.msg)(ansi reset)"
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
    #  is this pulling the transcript twice? 
        # let transcript = fabric -y $url


        let cmd_result = ($transcript | fabric $prompt)

        # Clean the output using the helper function
        clean_fabric_output $cmd_result

    } catch {
        |e| match ($e | is-empty) {
            true => {
                print $"(ansi yellow)Fabric command returned empty output(ansi reset)"
                return ""
            }
            false => {
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
    let safe_title = ($rating_data | get -i suggested-title | default "Review" | str trim)
    let safe_name = ($rating_data | get -i name | default "Unknown" | str trim)

    # Process labels and suggested tags
    let labels = ($rating_data | get -i labels | default "" | split row "," | each {|label| $"[[($label | str trim)]]"} | str join " ")
    let suggested_tags = ($rating_data | get -i suggested-tags | default "" | split row "," | each {|tag| $"[[($tag | str trim)]]"} | str join " ")

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

        $"***($rating_data.'one-sentence-summary' | default '')\n***",
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
    let rating_value_str = ($rating | get -i rating | default "0" | into string)
    let rating_num = try {
        $rating_value_str | split row ":" | first | str trim | into int
    } catch {
        print $"(ansi yellow)Warning: Could not parse rating number from '($rating_value_str)'. Assuming 0.(ansi reset)"
        0
    }
    print $"(ansi blue)Rating: (ansi reset)($rating_num).($rating.one-sentence-summary)"
    if $rating_num <= 3 {
        print $"(ansi yellow)Rating too low. Skipping review.(ansi reset)"
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
    let safe_title = ($rating | get -i suggested-title | default "Review" | str trim)
    let safe_name = ($rating | get -i name | default "Unknown" | str trim)
    let review_filename = $'($safe_title) - ($safe_name) (date now | format date "%m-%d-%Y").md'
    let review_filepath = ($target_dir | path join $review_filename) # Use full path

    # --- 4. Execute Fabric Review ---
    let review_content = (execute_fabric_review $url ($rating | get -i 'suggested-prompt' | default 'Summarize this video') $rating.transcript)

    if $review_content == null {
        print $"(ansi red)Fabric review command failed. Aborting file save.(ansi reset)"
        cd $original_dir # Return to original directory on failure
        return
    }

    if ($review_content | is-empty) {
        print $"(ansi yellow)Fabric review resulted in empty content. Saving header only.(ansi reset)"
    } else {
        print $"(ansi green)Fabric review completed. (emoji :thumbsup:)(ansi reset)"
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

# New exported function to add a channel
export def "add-channel" [
    channel_url: string, # The URL of the channel page (e.g., https://www.youtube.com/@SomeChannel)
    name: string         # The desired name for the channel in the feed list
] {
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
    # Assuming defaultFeeds.nu is in the same directory or NU_LIB_DIRS includes its location.
    let feeds_file_path = "~/dev/nushell/yt-review/defaultFeeds.nu" | path expand

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
    open ("~/dev/nushell/yt-review/.env" | path expand) | from toml | load-env

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
    if $latest_urls != null {
        for link in $latest_urls {
            #print $"Processing ($link.name): ($link.url)"
            let rating = get_fabric_rating $link.url $link.name
            if $rating != null {
                review_url $link.url $rating
            } else {
                print $"(ansi red)Failed to get rating for ($link.name) (ansi reset)($link.url)"
            }
        }
    } else {
        print $"(ansi yellow)No new videos found(ansi reset)"
    }
}


#6/3/25 Got it running again.  Lost the updated 'tag_and_rate' prompt with the re-install, that will need some work. 
#TODO:  Fix the Saving_Titles_With_underscores thing. 
#TODO: Update the prompt rating system. 

#TODO: Handle channels that put out multiple videos per day. Pull the first 3 urls from the feed and review if they are new.
#TODO: a function to just add labels/tags to files that already exist.




# this script should:
#take a url as an argument or piped input.
# run it through 'fabric label_and_rate'. Customize the prompt with new tags and themes. Have it reccomend a fabric prompt from a few options.
#   have it reccomend a fabric prompt from a few options.
#   have it come up with a title for the saved .md file, to include date, channel, and title of the post.
# if it is 'A' or 'S' tier, run 'fabric -y {chosen_promtp} {chosen_url} --output={title}.md'
# if no input is provided, check a few rss feeds for new posts.
# if they do, scrape the url for the latest post and run it through the same process.
