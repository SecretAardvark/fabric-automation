# Define YouTube channels and their RSS feeds
# Format: https://www.youtube.com/feeds/videos.xml?channel_id=CHANNEL_ID

# Define feeds at the top level
let feeds = [
    {
        name: "Spoon Fed Study"
        url: "https://www.youtube.com/feeds/videos.xml?channel_id=UC1Co9XZd52hiVrePGZ8qfoQ"
    }
    # {
    #     name: "Invest Answers"
    #     url: "https://www.youtube.com/feeds/videos.xml?channel_id=UCH6KS5IiLfTyunVHPCDYT8Q"
    # }
    # {
    #     name: "Camel Finance"
    #     url: "https://www.youtube.com/feeds/videos.xml?channel_id=UCr_DLep7UQ0B_IFhvTORu8A"
    # }
    # {
    #     name: "Dynamo Defi"
    #     url: "https://www.youtube.com/feeds/videos.xml?channel_id=UCEL45QB7k-UnGa05GAx6HZA"
    # }
    # {
    #     name: "Clark Kegley"
    #     url: "https://www.youtube.com/feeds/videos.xml?channel_id=UC-dmJ79518WlKMbsu50eMTQ"
    # }
    # {
    #     name: "The Calculator Guy"
    #     url: "https://www.youtube.com/feeds/videos.xml?channel_id=UCPIMrjFNbYwsbCuZdgEaqeA"
    # }
    # {
    #     name: "Breaking Points"
    #     url: "https://www.youtube.com/feeds/videos.xml?channel_id=UCDRIjKy6eZOvKtOELtTdeUA"
    # }
]

def get_latest_urls [] {
    # Return a list of RSS feeds for specific YouTube channels
    # You can find channel IDs by:
    # 1. Going to the channel page
    # 2. Right click > View Page Source
    # 3. Search for "channelId"
    mut latestVideos: list<record> = []
    mut videoList = (open videolist.txt | lines | uniq)
    if $videoList == null {
        touch videolist.txt
        mut videoList = []
    }
    
    for feed in $feeds {
        print $"Checking ($feed.name)..."
        let feed_url = (parse_rss $feed.url | first)  # Get single URL
        
        # Debug print
        # print $"Found URL: ($feed_url)"
        
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
    # let raw_output = (fabric -y $url | fabric -p tag_and_rate)
    # print $"Raw Output: ($raw_output)"
    
    # # let think_content = (
    # #     $raw_output
    # #     | lines
    # #     | skip while {|line| not $line =~ "<think>" }
    # #     | skip 1
    # #     | take while {|line| not $line =~ "</think>" }
    # #     | str join "\n"
    # # )
    
    # # Extract the JSON content between ```json and ```
    # mut rating = (
    #     $raw_output
    #     | lines
    #     | skip while {|line| not ($line | str contains "```json") }
    #     | skip 1
    #     | take while {|line| not ($line | str contains "```") }
    #     | str join "\n"
    #     | str trim
    #     | from json
    # )
    # $rating | describe
    # if ($rating | describe) == "record" {
    #     print $"Rating successfully parsed."
    #     review_url $url $rating  
    # } else {
    #     print $"Error: JSON part not found in the fabric output for URL: $url"
    # }

    #non chain of reasoning model path 
    mut rating = (fabric -y $url | fabric -p tag_and_rate | from json)
    $rating = ($rating | merge {name: $feed_name})
    print $"Rating: ($rating)" #debug
    review_url $url $rating
}

def review_url [url: string, rating: record, ] {
    # Extract just the number from the rating string (e.g., "4: (Highly Relevant...)" -> 4)
    let rating_num = ($rating.rating | split row ":" | first | into int)
    #print $"Rating: ($rating_num)"
    if $rating_num > 3 {
        if (pwd) != '~/Documents/Obsidian Vault/fabric' {
            cd '~/Documents/Obsidian Vault/fabric'
        }
        print $'Analyzing video with: ($rating.suggested-prompt)'
       # let feed_name = (if ($feeds | where url == $url | length) > 0 { $feeds | where url == $url | get name | first } else { "" })
        let title = $'($rating.suggested-title | str trim -c " ")($rating.name | if $in == "" { "" } | str trim -c " ") (date now | format date "%d-%m-%Y").md'
        print $"Title: ($title)"
        
        # First create the file with fabric output
        fabric -y $url | fabric $rating.suggested-prompt -s --output=$"($title)"
        
        # Then add labels as markdown links at top of file
        let labels = ($rating.labels | split row "," | each {|label| $"[[($label | str trim)]]"} | str join " ")
        #print $"Labels: ($labels)" #debug
        # Read the newly created file
        if ($title | path exists) {
            let file_content = (open $title | lines)
            let labels_array = ($labels | split row " ")
            let hashtag_labels = ($labels_array | each {|label| 
                $"#(($label | str replace -a '[[' '' | str replace -a ']]' ''))"
            })
            
            # Build header content first
            let header = [
                $"Channel: ($"([[$rating.name]])" | default "")",
                $"Labels: ($labels)",
                $"Tags: ($hashtag_labels | str join ' ')",
                $"Rating: ($rating.rating)",
                $"Analysed with: ($rating.suggested-prompt)",
                ""  # Empty line for spacing
            ]
            
            # Combine everything
            let new_content = ($header | append $file_content)
            
            # Debug print
            print $"Saving content with ($new_content | length) lines"
            
            $new_content | str join "\n" | save $title -f
            print $"File saved as: ($title)"
        } else {
            print $"Error: File ($title) was not created by fabric command"
        }
    }
}

# Main function to check feeds
export def main [...args: string] {
    
    # Prioritize command line arguments
    if not ($args | is-empty) {
        let url = $args.0
        print $"Processing URL from args: ($url)"
        get_fabric_rating $url ""
        return
    }

    # Check for piped input as fallback
    let input = $in
    if not ($input | is-empty) {
        print $"Processing URL from pipe: ($input)"
        get_fabric_rating $input ""
        return
    }

    # No input provided, run default flow
    print "No URL provided, checking feeds..."
    let latest_urls = get_latest_urls
    for link in $latest_urls {
        get_fabric_rating $link.url $link.name
    }
}

#TODO: add more youtube channels to the list. 
#TODO: fix tagging and Name generation. 
#TODO: Set it up as a module, source it in my nushell config. 
#TODO: Write the readme and clean up comments/formatting. 
#TODO: a function to just add labels/tags to files that already exist. 
# Run the script
#main

# this script should: 
# take a select few rss feeds and check if they have new posts. Maybe try 'fabric get_youtube_rss' first. 
# if they do, scrape the url for the latest post 
# run it through 'fabric label_and_rate'. Customize the prompt with new tags and themes. Have it reccomend a fabric prompt from a few options.
#   have it reccomend a fabric prompt from a few options. 
#   have it come up with a title for the saved .md file, to include date, channel, and title of the post. 
# if it is 'A' or 'S' tier, run 'fabric -y {chosen_promtp} {chosen_url} --output={title}.md'
