# Define YouTube channels and their RSS feeds
# Format: https://www.youtube.com/feeds/videos.xml?channel_id=CHANNEL_ID

# Define feeds at the top level
const feeds = [
    {
        name: "Spoon Fed Study"
        url: "https://www.youtube.com/feeds/videos.xml?channel_id=UC1Co9XZd52hiVrePGZ8qfoQ"
    },
    {
        name: "Invest Answers"
        url: "https://www.youtube.com/feeds/videos.xml?channel_id=UCH6KS5IiLfTyunVHPCDYT8Q"
    },
    {
        name: "Camel Finance"
        url: "https://www.youtube.com/feeds/videos.xml?channel_id=UCr_DLep7UQ0B_IFhvTORu8A"
    },
    {
        name: "Dynamo Defi"
        url: "https://www.youtube.com/feeds/videos.xml?channel_id=UCEL45QB7k-UnGa05GAx6HZA"
    },
    {
        name: "Clark Kegley"
        url: "https://www.youtube.com/feeds/videos.xml?channel_id=UC-dmJ79518WlKMbsu50eMTQ"
    },
    {
        name: "The Calculator Guy"
        url: "https://www.youtube.com/feeds/videos.xml?channel_id=UCPIMrjFNbYwsbCuZdgEaqeA"
    },
    {
        name: "Breaking Points"
        url: "https://www.youtube.com/feeds/videos.xml?channel_id=UCDRIjKy6eZOvKtOELtTdeUA"
    }
]

def get_latest_urls [] {
    # Return a list of RSS feeds for specific YouTube channels
    # You can find channel IDs by:
    # 1. Going to the channel page
    # 2. Right click > View Page Source
    # 3. Search for "channelId"
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
    mut rating: record = {}
    let start_index = ($raw_output | str index-of "{")
    let ai_thoughts = ($raw_output | str substring 0..$start_index)
    let json_string = ($raw_output | str substring $start_index..-1)
    print $"JSON String: ($json_string)"
    try {
        $rating = $json_string | from json 
        let type = ($rating | describe)
        if ($type | str starts-with "record") {
            try {
                let rating_with_name = { ...$rating, name: $feed_name }
                review_url $url $rating_with_name
                print $"review_url completed"
            } catch { |e|
                print $"Error calling review_url: ($e.message)"
            }
        } else {
            print $"Error: Parsed JSON is not a record for URL: ($url)"
            print $"Parsed content: ($rating)"
        }
    } catch {
        print $"Error: Could not parse JSON from fabric output for URL: ($url)"
    }
}

def review_url [url: string, rating: record] {
    let parts = ($rating | get rating | split row ":")
    let first_part = ($parts | first)
    try {
        let rating_num = ($first_part | str trim | into int)
        print $"Rating number: ($rating_num)"
        if $rating_num <= 3 {
            print "Meh... not worth it."
            return
        }
    } catch {
        print $"Error parsing rating: error message"
        return
    }

    if (pwd) != '~/Documents/Obsidian Vault/fabric' {
        try {
            cd '~/Documents/Obsidian Vault/fabric'
        } catch {
            print "Error: Failed to change directory to '~/Documents/Obsidian Vault/fabric'"
            return
        }
    }
    print $'Analyzing video with: ($rating.suggested-prompt)'
    let review_title = $'($rating.suggested-title | str trim -c " ")($rating.name  | str trim -c " ") (date now | format date "%m-%d-%Y").md'
    
   
    fabric -y $url | fabric $rating.suggested-prompt -s --output $review_title
    
    let labels = ($rating.labels | split row "," | each {|label| $"[[($label | str trim)]]"} | str join " ")
    
    if ($review_title | path exists) {
        let file_content = (open $review_title | lines)
        let labels_array = ($labels | split row " ")
        let hashtag_labels = ($labels_array | each {|label| 
            $"#(($label | str replace -a '[[' '' | str replace -a ']]' ''))"
        })
        
        let header = [
            $"Channel: ($"([[$rating.name]])" | default "")",
            $"Labels: ($labels)",
            $"Tags: ($hashtag_labels | str join ' ')",
            $"Rating: ($rating.rating)",
            $"Analysed with: ($rating.suggested-prompt)",
            ""  # Empty line for spacing
        ]
        
        let new_content = ($header | append $file_content)
        
        $new_content | str join "\n" | save $review_title -f
        print $"File saved as: ($review_title)"
    } else {
        print $"Error: File ($review_title) was not created by fabric command"
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

#TODO: Handle channels that put out multiple videos per day. Pull the first 3 urls from the feed. 
#TODO: a function to just add labels/tags to files that already exist. 
#TODO: fix the tool reviewing videos it's already reviewed. 

# this script should: 
#take a url as an argument or piped input. 
# run it through 'fabric label_and_rate'. Customize the prompt with new tags and themes. Have it reccomend a fabric prompt from a few options.
#   have it reccomend a fabric prompt from a few options. 
#   have it come up with a title for the saved .md file, to include date, channel, and title of the post. 
# if it is 'A' or 'S' tier, run 'fabric -y {chosen_promtp} {chosen_url} --output={title}.md'
# if no input is provided, check a few rss feeds for new posts. 
# if they do, scrape the url for the latest post and run it through the same process. 
