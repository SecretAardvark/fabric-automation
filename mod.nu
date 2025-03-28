use defaultFeeds.nu

def get_latest_urls [] {
    mut latestVideos: list<record> = []
    
    mut videoList = if ("~/dev/nushell/yt-review/videolist.txt" | path exists ) {
        (open videolist.txt | lines | uniq)
    } else {
        touch videolist.txt
        []
    }
    
    for feed in $feeds {
        #print $"Checking ($feed.name)..."
        let feed_url = (parse_rss $feed.url | first)  # Get single URL
        # Only append if URL is not in videoList
        if not ($videoList | any {|existing| $existing == $feed_url }) {
            print $"New video found for ($feed.name)"
            $videoList = ($videoList | append $feed_url)
            $latestVideos = ($latestVideos | append {
                name: $feed.name,
                url: $feed_url
            })
        }
    }
    
    # Save unique entries only
    $videoList | uniq | save videolist.txt -f 
    if $latestVideos == null {
        print $"No new videos found"
        return null
    } else {
        $latestVideos
    }
}


# Function to fetch RSS feed content
def parse_rss [url: string]  {
    http get $url
    | get content
    | where tag == entry
    | first
    | get content
    | where tag == link
    | get attributes
    | get href
}

# Helper function to safely parse JSON from fabric output
def parse_fabric_json [raw_output: string, url: string] {
    # Extract JSON from the output by removing the <think> block if present
    let json_string = if ($raw_output | str contains "<think>") and ($raw_output | str contains "</think>") {
        let parts = ($raw_output | split row "</think>")
        if ($parts | length) > 1 {
            # Take everything after the first </think> tag
            let after_think = ($parts | skip 1 | str join "" | str trim)
            
            # Find JSON object in the remaining text
            let start_index = ($after_think | str index-of "{")
            let end_index = ($after_think | str index-of "}")
            
            if $start_index != -1 and $end_index != -1 {
                $after_think | str substring $start_index..($end_index + 1)
            } else {
                print $"Error: Could not find JSON object after </think> tag for URL: ($url)"
                return null
            }
        } else {
            # Fallback if splitting didn't work as expected
            let start_index = ($raw_output | str index-of "{")
            let end_index = ($raw_output | str index-of "}")
            
            if $start_index != -1 and $end_index != -1 {
                $raw_output | str substring $start_index..($end_index + 1)
            } else {
                print $"Error: Could not find valid JSON markers in output for URL: ($url)"
                return null
            }
        }
    } else {
        # Fall back if <think> tags not found
        let start_index = ($raw_output | str index-of "{")
        let end_index = ($raw_output | str index-of "}")
        
        if $start_index != -1 and $end_index != -1 {
            $raw_output | str substring $start_index..($end_index + 1)
        } else {
            print $"Error: Could not find valid JSON markers in output for URL: ($url)"
            return null
        }
    }
    
    print $"JSON String: ($json_string)" # Optional: uncomment for debugging
    
    # Check if json_string is actually a string
    if (($json_string | describe) !~ "string") {
        print $"Error: Potential JSON content is not a string type: ($json_string | describe)"
        return null
    }
    
    try {
        let parsed_json = ($json_string | from json)
        return $parsed_json
    } catch {
        |e| print $"Error: Could not parse JSON from fabric output for URL: ($url): ($e.msg)"
        print $"Raw output was: ($raw_output)"
        print $"Attempted to parse: ($json_string)"
        return null
    }
}

def get_fabric_rating [url: string, feed_name: string] {
    let raw_output = (fabric -y $url | fabric -p tag_and_rate)
    
    # Check if we got any output at all
    if ($raw_output | is-empty) {
        print $"Error: No output received from fabric for URL: ($url)"
        return null
    }

    let rating_data = (parse_fabric_json $raw_output $url)
    
    if $rating_data == null {
        # Error already printed in parse_fabric_json
        return null
    }
    
    # Check if the result is a record
    if ($rating_data | describe) =~ "^record" {
        # Add the feed name to the rating record
        { ...$rating_data, name: $feed_name }
    } else {
        print $"Error: Parsed JSON is not a record for URL: ($url)"
        print $"Parsed content type: ($rating_data | describe)"
        print $"Parsed content: ($rating_data)"
        return null
    }
}

# Helper function to ensure the review directory exists
def ensure_review_directory [] {
    let vault_dir = $"~/Documents/Obsidian Vault/fabric/(date now | format date '%m-%d-%Y')"
    # Expand the path to resolve the tilde
    let expanded_vault_dir = ($vault_dir | path expand)
    
    # Check if directory exists and create if not
    if not ($expanded_vault_dir | path exists) {
        try {
            mkdir $expanded_vault_dir
            print $"Created directory: ($expanded_vault_dir)"
        } catch {
            |e| print $"Error: Failed to create directory ($expanded_vault_dir): ($e.msg)"
            return null # Indicate failure
        }
    }
    $expanded_vault_dir # Return the path
}

# Helper function to execute the main fabric review command
def execute_fabric_review [url: string, prompt: string] {
    print $'Analyzing video with prompt: ($prompt)'
    print "Running fabric command..."
    
    try {
        let cmd_result = (fabric -y $url | fabric $prompt -s)
        
        if ($cmd_result | is-empty) {
            print "Warning: Fabric command returned empty output"
            return "" # Return empty string instead of null for easier handling
        }
        
        # Clean the output - remove <think> blocks
        if ($cmd_result | str contains "<think>") and ($cmd_result | str contains "</think>") {
            let parts = ($cmd_result | split row "</think>")
            if ($parts | length) > 1 {
                $parts | skip 1 | str join "" | str trim
            } else {
                $cmd_result # Fallback
            }
        } else {
            $cmd_result # No think tags found
        }
    } catch {
        |e| print $"Error running fabric command: ($e.msg)"
        return null # Indicate failure
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
        $"Channel: ([[$safe_name]])",
        $"Labels: ($all_labels)",
        $"Tags: ($hashtag_labels | str join ' ')",
        $"Rating: ($rating_data.rating | default 'N/A')",
        $"Analysed with: ($rating_data.'suggested-prompt' | default 'N/A')",
        $"Summary: ($rating_data.'one-sentence-summary' | default '')",
        ""  # Empty line for spacing
    ]
    
    # Combine header and review content
    let final_content = ($header | append $review_content) | str join "\n"
    
    # Save the file
    try {
        $final_content | save -f $file_path
        print $"File successfully saved: ($file_path)"
        return true # Indicate success
    } catch {
        |e| print $"Error saving file ($file_path): ($e.msg)"
        return false # Indicate failure
    }
}

def review_url [url: string, rating: record] {
    # --- 1. Check Rating ---
    let rating_value_str = ($rating | get -i rating | default "0" | into string)
    let rating_num = try {
        $rating_value_str | split row ":" | first | str trim | into int
    } catch {
        print $"Warning: Could not parse rating number from '($rating_value_str)'. Assuming 0."
        0
    }

    print $"Parsed rating number: ($rating_num)"
    if $rating_num <= 3 {
        print "Rating too low. Skipping review."
        return
    }

    # --- 2. Ensure Directory and Change To It ---
    let target_dir = (ensure_review_directory)
    if $target_dir == null {
         # Error already printed by helper function
        return 
    }
    
    # Store current directory to return to it later
    let original_dir = (pwd)
    
    # Change to the directory
    try {
        cd $target_dir
        # print $"Changed directory to: (pwd)" # Optional: uncomment for debugging
    } catch {
        |e| print $"Error: Failed to change directory to ($target_dir): ($e.msg)"
        return # Cannot proceed without correct directory
    }

    # --- 3. Prepare Filename ---
    let safe_title = ($rating | get -i suggested-title | default "Review" | str trim)
    let safe_name = ($rating | get -i name | default "Unknown" | str trim)
    let review_filename = $'($safe_title) - ($safe_name) (date now | format date "%m-%d-%Y").md'
    let review_filepath = ($target_dir | path join $review_filename) # Use full path

    # --- 4. Execute Fabric Review ---
    let review_content = (execute_fabric_review $url ($rating | get -i 'suggested-prompt' | default 'Summarize this video'))
    
    if $review_content == null {
        print "Fabric review command failed. Aborting file save."
        cd $original_dir # Return to original directory on failure
        return 
    }
    
    if ($review_content | is-empty) {
        print "Fabric review resulted in empty content. Saving header only."
    } else {
        print "Fabric review completed."
    }

    # --- 5. Format and Save File ---
    let save_success = (format_and_save_review $review_filepath $review_content $rating)

    # --- 6. Return to Original Directory ---
    cd $original_dir
    # print $"Returned to directory: (pwd)" # Optional: uncomment for debugging

    if not $save_success {
        print "Failed to save the review file."
        # Potentially add more cleanup or error reporting here
    }
}

export def "main get-channel-ID" [channel_url: string] {
    http get $channel_url | 
    to text | 
    parse --regex '<link[^>]*?href="(https://www.youtube.com/channel/[^"]+)"[^>]*?>' | 
    get capture0 | 
    first
}

# def add_channel_rss [url: string, name: string] {
#     let channel_id = (yt-review get-channel-ID $url)
#     print $"Channel ID: ($channel_id)"
#     let new_url = $"https://www.youtube.com/feeds/videos.xml?channel_id=($channel_id)"
#     print $"New URL: ($new_url)"
#     $feeds = ($feeds | append [{
#         name: $name,
#         url: $new_url
#     }])

# }
# Main function to check feeds
export def main [...args: string] {
    if not ($args | is-empty) {
        let url = $args.0
        let name = if ($args | length) > 1 { $args.1 } else { "" }
        print $"Processing URL from args: ($url)"
        let rating = get_fabric_rating $url $name
        if $rating != null {
            review_url $url $rating
        }
        return
    }

    let input = $in
    if not ($input | is-empty) {
        let name = if ($input | length) > 1 { $input.1 } else { "" }
        print $"Processing URL from pipe: ($input)"
        let rating = get_fabric_rating $input $name 
        if $rating != null {
            review_url $input.0 $rating
        }
        return
    }

    print "No URL provided, checking feeds..."
    let latest_urls = get_latest_urls
    if $latest_urls != null {
        for link in $latest_urls {
            let rating = get_fabric_rating $link.url $link.name
            if $rating != null {
                review_url $link.url $rating
            }
        }
    }
    print "No new videos found"
}

#TODO: Handle channels that put out multiple videos per day. Pull the first 3 urls from the feed and review if they are new. 
#TODO: a function to just add labels/tags to files that already exist. 

#TODO: Expand the get-channel-ID function to add the channel ID to the default feeds. 



# this script should: 
#take a url as an argument or piped input. 
# run it through 'fabric label_and_rate'. Customize the prompt with new tags and themes. Have it reccomend a fabric prompt from a few options.
#   have it reccomend a fabric prompt from a few options. 
#   have it come up with a title for the saved .md file, to include date, channel, and title of the post. 
# if it is 'A' or 'S' tier, run 'fabric -y {chosen_promtp} {chosen_url} --output={title}.md'
# if no input is provided, check a few rss feeds for new posts. 
# if they do, scrape the url for the latest post and run it through the same process. 
