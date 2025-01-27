#!/home/ch4d/.cargo/bin/nu

# Define YouTube channels and their RSS feeds
# Format: https://www.youtube.com/feeds/videos.xml?channel_id=CHANNEL_ID

def get_latest_urls [] {
    # Return a list of RSS feeds for specific YouTube channels
    # You can find channel IDs by:
    # 1. Going to the channel page
    # 2. Right click > View Page Source
    # 3. Search for "channelId"
    let feeds = [
        {
            name: "Spoon Fed Study"
            url: "https://www.youtube.com/feeds/videos.xml?channel_id=UC1Co9XZd52hiVrePGZ8qfoQ"
        }
        {
            name: "Invest Answers"
            url: "https://www.youtube.com/feeds/videos.xml?channel_id=UCH6KS5IiLfTyunVHPCDYT8Q"
        }
        {
            name: "Camel Finance"
            url: "https://www.youtube.com/feeds/videos.xml?channel_id=UCr_DLep7UQ0B_IFhvTORu8A"
        }
    ]
    # Read existing videos, ensure unique entries
    mut latest_urls = []
    mut videoList = (open videolist.txt | lines | uniq)
    if $videoList == null {
        touch videolist.txt
        mut videoList = []
    }
    
    for feed in $feeds {
        print $"Checking ($feed.name)..."
        $latest_urls = (parse_rss $feed.url)
        
        # Only append if truly new
        if ($videoList | where $it == $latest_urls | length) == 0 {
            $videoList = ($videoList | append $latest_urls)
        }
    }
    
    # Save unique entries only
    $videoList | uniq | save videolist.txt -f 
    $latest_urls 
}

# Function to fetch RSS feed content
def parse_rss [url: string] {
    http get $url
    | get content
    | where tag == entry
    | first
    | get content
    | where tag == link
    | get attributes
    | get href
}

def get_fabric_rating [url: string] {
    let rating = fabric -y $url | fabric -sp tag_and_rate
}

# Main function to check feeds
def main [...args: string] {
    
    # Check if we have command line arguments
    if  not ($in| is-empty) {
        # Get the first argument
        let input = $in
        # Get the second argument (with default value if not provided)
        #let output_file = ($in | get 1 "default_output.md")
        let url = $input.0
        # Use the arguments
        let rating = get_fabric_rating $url
        if ($rating.rating | into int) > 3 {
            fabric -y $url | fabric $rating.suggested-prompt -s $'~/Documents/Obsidian Vault/fabric/($rating.suggested-title)().md'
        }
    } else {
        # No arguments provided, run the default flow
        get_latest_urls
    }
}

# Run the script
#main

# this script should: 
# take a select few rss feeds and check if they have new posts. Maybe try 'fabric get_youtube_rss' first. 
# if they do, scrape the url for the latest post 
# run it through 'fabric label_and_rate'. Customize the prompt with new tags and themes. Have it reccomend a fabric prompt from a few options.
#   have it reccomend a fabric prompt from a few options. 
#   have it come up with a title for the saved .md file, to include date, channel, and title of the post. 
# if it is 'A' or 'S' tier, run 'fabric -y {chosen_promtp} {chosen_url} --output={title}.md'
#open the created file and add the tags as [[]] at the top. 