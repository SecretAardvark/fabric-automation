# Fabric Automation

A Nushell script for automating YouTube content processing with [Fabric](https://github.com/danielmiessler/fabric), a neat AI cli tool. I've been trying to cut back on how much time i waste on youtube, so i was using fabric to summarize videos or take quick notes on them without having to watch.

This script automates common tasks i was doing. It will process the transcript from a youtube URL and rate it depending on a custom fabric prompt (pattern) that i wrote, decide on the most relevant fabric prompt to review the content with, and then review it, saving the output with relevant tags in my Obsidian markdown vault.

## Installation

1. Ensure Fabric is installed. Follow the instructions in their [repo.](https://github.com/danielmiessler/fabric?tab=readme-ov-file#installation)
2. Clone the repository
3. Customize the default feeds and tag_and_rate prompt. Your tastes and interests will be different than mine, obviously.
4. Source the script in your Nushell config

## Usage

```nu
# Process a single URL
yt-review "https://youtube.com/..."
#or
"https://youtube.com/..." | yt-review

# This will pull all the latest videos to review from your default channels.
yt-review
```
