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
        print $"Checking ($feed.name)..."
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

def get_fabric_rating [url: string, feed_name: string] {
    let raw_output = (fabric -y $url | fabric -p tag_and_rate)
    mut rating = null
    
    # First check if we got any output at all
    if ($raw_output | is-empty) {
        print $"Error: No output received from fabric for URL: ($url)"
        return null
    }

    # Extract JSON from the output by removing the <think> block
    let json_string = if ($raw_output | str contains "<think>") and ($raw_output | str contains "</think>") {
        # Split the string by "</think>" and take everything after it
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
            # Fallback to original method
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
        # Fall back to original method if <think> tags not found
        let start_index = ($raw_output | str index-of "{")
        let end_index = ($raw_output | str index-of "}")
        
        if $start_index != -1 and $end_index != -1 {
            $raw_output | str substring $start_index..($end_index + 1)
        } else {
            print $"Error: Could not find valid JSON markers in output for URL: ($url)"
            return null
        }
    }
    
    print $"JSON String: ($json_string)"
    
    # Check if json_string is actually a number or other non-string type
    if (($json_string | describe) !~ "string") {
        print $"Error: JSON string is not a string type: ($json_string | describe)"
        return null
    }
    
    try {
        # Convert the JSON string to a record
        $rating = ($json_string | from json)
        
        # Check if the result is a record
        if ($rating | describe) =~ "^record" {
            let rating_with_name = { 
                ...$rating, 
                name: $feed_name 
            }
            return $rating_with_name
        } else {
            print $"Error: Parsed JSON is not a record for URL: ($url)"
            print $"Parsed content type: ($rating | describe)"
            print $"Parsed content: ($rating)"
            return null
        }
    } catch {
        |e| print $"Error: Could not parse JSON from fabric output for URL: ($url): ($e.msg)"
        print $"Raw output: ($raw_output)"
        return null
    }
}

def review_url [url: string, rating: record] {
    # Make sure rating is a string before splitting
    let rating_value = if ($rating | get -i rating) != null {
        $rating.rating | into string
    } else {
        "0"
    }
    
    # Now split the rating string
    let parts = ($rating_value | split row ":")
    let first_part = ($parts | first)
    
    try {
        let rating_num = ($first_part | str trim | into int)
        print $"Rating number: ($rating_num)"
        if $rating_num <= 3 {
            print "Meh... not worth it."
            return
        }
    } catch {
        |e| print $"Error parsing rating: ($e.msg)"
        return
    }

    # Create directory path variable for reuse
    
    let vault_dir = $"~/Documents/Obsidian Vault/fabric/(date now | format date "%m-%d-%Y")"
    # Expand the path to resolve the tilde
    let expanded_vault_dir = ($vault_dir | path expand)
    
    # Check if directory exists
    if not ($expanded_vault_dir | path exists) {
        mkdir $expanded_vault_dir
        print $"Created directory: ($expanded_vault_dir)"
    }
    
    # Store current directory to return to it later
    let original_dir = (pwd)
    
    # Change to the directory
    try {
        cd $expanded_vault_dir
        print $"Changed directory to: (pwd)"
    } catch {
        |e| print $"Error: Failed to change directory to ($expanded_vault_dir): ($e.msg)"
        return
    }
    
    print $'Analyzing video with: ($rating.suggested-prompt)'
    
    # Create a safer filename
    let safe_title = if ($rating | get -i suggested-title) != null {
        $rating.suggested-title | str trim
    } else {
        "Review"
    }
    
    let safe_name = if ($rating | get -i name) != null {
        $rating.name | str trim
    } else {
        "Unknown"
    }
    
    let review_title = $'($safe_title) - ($safe_name) (date now | format date "%m-%d-%Y").md'
    #print $"Will save to file: ($review_title)"
    
    # Run fabric command and capture output with better error handling
    print "Running fabric command..."
    let cmd_result = do {
        try {
            let result = (fabric -y $url | fabric $rating.suggested-prompt -s)
            if ($result | is-empty) {
                print "Warning: Fabric command returned empty output"
                null
            }
            $result
        } catch {
            |e| print $"Error running fabric command: ($e.msg)"
            null
        }
    }
    
    # Check if output is empty or null
    if ($cmd_result == null) {
        print "Error: No output received from fabric command"
        cd $original_dir
        return
    }
    
    print "Fabric review completed"
    
    # Process the output - handle <think> blocks
    let cleaned_output = if ($cmd_result | str contains "<think>") and ($cmd_result | str contains "</think>") {
        # Split the string by "</think>" and take everything after it
        let parts = ($cmd_result | split row "</think>")
        if ($parts | length) > 1 {
            # Take everything after the first </think> tag and trim whitespace
            $parts | skip 1 | str join "" | str trim
        } else {
            # Fallback to original content if splitting didn't work as expected
            $cmd_result
        }
    } else {
        # If no think tags, use the original output
        $cmd_result
    }
    
    # Save the file with proper path handling
    try {
        $cleaned_output | save -f $review_title
        #print $"Successfully saved file: ($review_title)"
    } catch {
        |e| print $"Error saving file: ($e.msg)"
        cd $original_dir
        return
    }
    
    # Process both labels and suggested tags
    let labels = if ($rating | get -i labels) != null {
        $rating.labels | split row "," | each {|label| $"[[($label | str trim)]]"} | str join " "
    } else {
        ""
    }
    
    let suggested_tags = if ($rating | get -i suggested-tags) != null {
        $rating.suggested-tags | split row "," | each {|tag| $"[[($tag | str trim)]]"} | str join " "
    } else {
        ""
    }
    
    if ($review_title | path exists) {
        let file_content = (open $review_title | 
                        str join "\n" |
                        if ($cleaned_output | str contains "</think>") {
                            split row "</think>" | 
                            skip 1 | 
                            str join "" | 
                            str trim | 
                            lines
                            } else {
                                lines
                            })
        let all_labels = ([$labels, $suggested_tags] | str join " " | str trim)
        let labels_array = ($all_labels | split row " ")
        let hashtag_labels = ($labels_array | each {|label| 
            $"#(($label | str replace -a '[[' '' | str replace -a ']]' ''))"
        })
        
        let header = [
            $"Channel: ($"([[$safe_name]])" | default "")",
            $"Labels: ($all_labels)",
            $"Tags: ($hashtag_labels | str join ' ')",
            $"Rating: ($rating.rating)",
            $"Analysed with: ($rating.suggested-prompt)",
            ""  # Empty line for spacing
        ]
        
        let new_content = ($header | append $rating.one-sentence-summary | append $file_content)
        
        $new_content | str join "\n" | save $review_title -f
        print $"File successfully saved with header: ($review_title)"
    } else {
        print $"Error: File ($review_title) was not created by fabric command"
    }
    
    # Return to original directory
    cd $original_dir
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
}

#TODO: Handle channels that put out multiple videos per day. Pull the first 3 urls from the feed. 
#TODO: a function to just add labels/tags to files that already exist. 
#TODO: fix the tool reviewing videos it's already reviewed. 
#TODO: Improve and refine the rating prompt. It never rejects any videos, i haven't seen a rating < 4.
#TODO: Expand the get-channel-ID function to add the channel ID to the default feeds. 



# this script should: 
#take a url as an argument or piped input. 
# run it through 'fabric label_and_rate'. Customize the prompt with new tags and themes. Have it reccomend a fabric prompt from a few options.
#   have it reccomend a fabric prompt from a few options. 
#   have it come up with a title for the saved .md file, to include date, channel, and title of the post. 
# if it is 'A' or 'S' tier, run 'fabric -y {chosen_promtp} {chosen_url} --output={title}.md'
# if no input is provided, check a few rss feeds for new posts. 
# if they do, scrape the url for the latest post and run it through the same process. 
