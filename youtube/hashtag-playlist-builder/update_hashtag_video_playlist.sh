#!/bin/bash
###############################################
# YouTube Hashtag Playlist Maintainer Script
# 
# 9/28/2021 Chris Lenderman 
#             Initial Version
#
# 12/5/2021 Chris Lenderman
#              Updated Version
###############################################

# QuickStart:
# 1) Save script on a Linux system as update_hashtag_video_playlist.sh, let's say in a directory called /data/list
# 2) Update all variables in the script below under GOOGLE CREDENTIAL SETTINGS AND INSTRUCTIONS
# 3) Update settings of interest in the script below under SPECIFIC PARAMETERS
# 4) Update crontab to run this once per day, this example will run at 8 a.m. 
#    crontab -e 
#    0 8 * * *  /data/list/update_hashtag_video_playlist.sh
# 5) Make sure that your playlist got updated as expected.. either in YouTube or by looking at some logs:
#    /data/list/log/playlist_update_history.log
#    /data/list/log/status.log
#  6) Also, for advanced debugging, we do output the following logs as well:
#    /data/list/debug/playlist_addition_history.log
#    /data/list/debug/raw_global_search_results_output.log
#    /data/list/debug/raw_specific_video_search_output.log


# NOTE: This script is a work in progress.  
#       Feel free to offer constructive criticism.
#       If you have unconstructive criticism, you can just keep that to yourself :)


# NOTE: I have noticed that search results from the YouTube Data API v3 has been inconsistent!!!
#       As such, on different days, you may get different video returns from search results.
#       This script will add any videos to a playlist that do not exist in said playlist, so
#       in that respect, we do "self heal" a bit.


# NOTE: This script is stateless, and it has to be.  Google Cloud Platform accounts cap usage at
# 10,000 units per day.  If we were in the middle of, say, getting video results, and then
# went to rebuild a playlist from scratch, in a stateful world, this could wreck the playlist!!
#
# As such, this is how the script works:
#
# 1) Perform searches based on a defined set of hashtag phrases and make a list of found videos
# 2) For each of the found videos, get specific information about them
# 3) Once we have the specific info, look through all of the metadata for matches on hashtag phrases
# 4) Also, use the specific information to restrict videos based on dates and if they are premieres 
#    that aren't visible on YouTube yet
# 5) Save off the videos that make the cut to a list
# 6) Retrieve the current playlist
# 7) Compare the playlist to videos that made the cut
# 8) For any videos that made the cut and are not in the playlist, add them to the playlist
#
# Notice how we NEVER remove an existing video from the playlist or rebuild the playlist, we only ever update it


# YouTube Data APIs used in this script:
#
#  GET https://www.googleapis.com/youtube/v3/search (Search: list)
#    Docs: https://developers.google.com/youtube/v3/docs/search/list
#
#  GET https://www.googleapis.com/youtube/v3/videos (Videos: list)
#    Docs: https://developers.google.com/youtube/v3/docs/videos/list
#
#  GET https://www.googleapis.com/youtube/v3/playlistItems (PlaylistItems: list)
#    Docs: https://developers.google.com/youtube/v3/docs/playlistItems/list
#
#  POST https://www.googleapis.com/youtube/v3/playlistItems (PlaylistItems: insert)
#    Docs: https://developers.google.com/youtube/v3/docs/playlistItems/insert


###############################################
## GOOGLE CREDENTIAL SETTINGS AND INSTRUCTIONS
###############################################

# Go to your Google Cloud Platform Account and create a new project
# Then go to APIs & Services, Dashboard, Enable APIs And Services, search for YouTube Data API v3, click on the search result, and choose Enable

# Google API Key
# In Google Cloud Platform, go to APIs & Services, then Credentials, then Create Credentials, and create an API Key
# Paste your API Key here:
GOOGLE_API_KEY=""

# Back in Google Cloud Platform, go to APIs & Services, then OAuth Consent Screen
# For User Type, choose External, and click Create
# Give your "app" a name (any name is fine) and set the "user support email" (can be any email address of yours), then set the "developer contact email", then click Save and Continue
# For Scopes, just click Save and Continue
# For Test Users, just click Save and Continue
# Then click back on OAuth Consent Screen and click Publish App, then click Confirm
# Then go to APIs & Services, Credentials, Create Credentials, and create an OAuth Client ID
# For application type, choose Desktop app, and give it a name, any name, then click Create
# You will get a Client ID and Client Secret, set them here:
GOOGLE_CLIENT_ID=""
GOOGLE_CLIENT_SECRET=""

# Replace <client_id> below with your Client ID and paste this in your web browser:
# https://accounts.google.com/o/oauth2/v2/auth?scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fyoutubepartner&response_type=code&client_id=<client_id>&redirect_uri=urn:ietf:wg:oauth:2.0:oob&access_type=offline
# Choose the account associated with the account that has your YouTube playlist that you want to update
# Then choose your YouTube channel that owns the playlist
# If prompted with "Google has not authorized this app", Click "advanced" and then "Go to <your Google Cloud Platform app name> (unsafe)"
# Click Allow
# You'll get back a "code" that you can then use to get a refresh token. Make a note of it.
# Next, export your GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, and this new "code" as GOOGLE_API_CODE.  Then call cURL to get your refresh token.
# For example:
#   export GOOGLE_CLIENT_ID=<your Client ID from above>
#   export GOOGLE_CLIENT_SECRET=<your Client Secret from above
#   export GOOGLE_API_CODE=<the "code" that you got back from your web browser>
#   curl --request POST --data "code=$GOOGLE_API_CODE&client_id=$GOOGLE_CLIENT_ID&client_secret=$GOOGLE_CLIENT_SECRET&redirect_uri=urn:ietf:wg:oauth:2.0:oob&grant_type=authorization_code" https://accounts.google.com/o/oauth2/token
# You'll get back a refresh token as part of the response.  Go ahead and paste it here:
GOOGLE_REFRESH_TOKEN=""

# The name of your account above.  Optional, but helpful for bookkeeping
ACCT_ID="MyAccount"


###############################################
## SPECIFIC PARAMETERS
###############################################

# The hashtag search phrase!
SEARCH_PHRASES=("doscember" "doscember2021")

# The video playlist to update.  This would be a playlist that you have already created in your YouTube account, the ID will be a part of the URL when you navigate to it.
PLAYLIST=''

# The allowed video start and end dates for adding new videos to your playlist (I do this to not get videos from past years hashtag events)
VIDEO_START_DATE="11/30/2021"
VIDEO_END_DATE="1/2/2022"


###############################################################################################
AS A RULE OF THUMB, YOU SHOULDN'T HAVE TO UPDATE ANYTHING BELOW THIS LINE
###############################################################################################

#------------------------------------------------------------------------------------------------


###############################################
## Global Settings
###############################################
# The current directory that the script is running in
SCRIPTPATH=$(cd `dirname $0` && pwd)
DATAPATH=$SCRIPTPATH/data
LOGPATH=$SCRIPTPATH/log
DEBUGPATH=$SCRIPTPATH/debug


###############################################
## FUNCTIONS
###############################################

# Joins an array of terms by delimiter
function join_by { local d=${1-} f=${2-}; if shift 2; then printf %s "$f" "${@/#/$d}"; fi; }


# Performs the overarching search for the search phrases of interest
function execute_search() {

  # Uncomment if you wish to debug!
  rm $DEBUGPATH/raw_global_search_results_output.txt 2> /dev/null

  for i in "${SEARCH_PHRASES[@]}"
  do
    unset NEXT_PAGE_TOKEN

    SEARCH_PHRASE=$i
    # Get first page of video results
    echo "$ACCT_ID `date` Performing Global Search of hash tag $SEARCH_PHRASE" | tee -a $LOGPATH/status.log
    perform_global_search

    # Get follow up pages of video results
    while [[ ! $NEXT_PAGE_TOKEN == "null" ]]
    do
      perform_global_search
    done 
  done
}

# Performs a global search given a search phrase
function perform_global_search() {
  
  # Calculate the search URL
  SEARCH_URL="https://www.googleapis.com/youtube/v3/search?part=snippet&q=%23%23$SEARCH_PHRASE&key=$GOOGLE_API_KEY&maxResults=50"

  if [[ ! -z "$NEXT_PAGE_TOKEN" ]]; then
    SEARCH_URL=" $SEARCH_URL&pageToken=$NEXT_PAGE_TOKEN"
  fi;
  
  # Uncomment if you wish to debug!
  echo $SEARCH_URL >> $DEBUGPATH/raw_global_search_results_output.txt

  # Call the Search API
  RESULT=`curl -s -X GET $SEARCH_URL`
  HASH_SEARCH_COST=$((HASH_SEARCH_COST+100))

  # Uncomment if you wish to debug!
  echo $RESULT >> $DEBUGPATH/raw_global_search_results_output.txt

  # Determine what the next page token to get the next page of search results
  NEXT_PAGE_TOKEN=`echo $RESULT | jq -r '.nextPageToken'`

  # Get a list of videos from the search results.  We could improve this by only searching for "video" type in our original search
  VIDEOS+=(`echo $RESULT  | jq -r ' .items[] | select ((.id.kind  == "youtube#video")) | .id.videoId'`)
}


# Performs a filtered video search given a video search list
function perform_filtered_video_search {

  # Perform the search, removing the last three characters from the search list since they are a stray delimiter
  CURL_CMD="https://www.googleapis.com/youtube/v3/videos?part=snippet&id=${VIDEO_SEARCH_LIST::-3}&key=$GOOGLE_API_KEY"

  # Uncomment if you wish to debug
  echo $CURL_CMD >> $DEBUGPATH/raw_specific_video_search_output.txt 

  RESULT=`curl -s -X GET $CURL_CMD`
  VIDEOS_SEARCH_COST=$((VIDEOS_SEARCH_COST+1))
 
  # Uncomment if you wish to debug
  echo $RESULT >> $DEBUGPATH/raw_specific_video_search_output.txt 

  START_DATE=`date -d $VIDEO_START_DATE +%s`
  END_DATE=`date -d $VIDEO_END_DATE +%s`

  SEARCH_PHRASE=$(join_by '|' ${SEARCH_PHRASES[@]})

  # For videos with tags, filter for the hashtag in the title, tags, or description, and only include videos between the dates desired that are not set to "premiere"
  FILTERED_VIDEOS+=(`echo $RESULT | jq -c -r --arg START_DATE $START_DATE --arg END_DATE $END_DATE --arg SEARCH_PHRASE $SEARCH_PHRASE '
  .items[] | 
    select((.snippet.publishedAt | fromdateiso8601 > ($START_DATE | tonumber)) and 
      (.snippet.publishedAt | fromdateiso8601 < ($END_DATE | tonumber))) | 
    select (.snippet.tags != null) | 
    select ((.snippet.description | test ($SEARCH_PHRASE; "i")) or 
      (.snippet.title | test ($SEARCH_PHRASE; "i")) or 
      (.snippet.tags[] | test ($SEARCH_PHRASE; "i"))) | 
    select (.snippet.liveBroadcastContent | test ("none")) | .id'`)

  # For videos without tags, filter for the hashtag in the title or description, and only include videos between the dates desired that are not set to "premiere"
  FILTERED_VIDEOS+=(`echo $RESULT | jq -c -r --arg START_DATE $START_DATE --arg END_DATE $END_DATE --arg SEARCH_PHRASE $SEARCH_PHRASE '
  .items[] | 
    select((.snippet.publishedAt | fromdateiso8601 > ($START_DATE | tonumber)) and 
      (.snippet.publishedAt | fromdateiso8601 < ($END_DATE | tonumber))) | 
    select (.snippet.tags == null) | 
    select ((.snippet.description | test ($SEARCH_PHRASE; "i")) or 
      (.snippet.title | test ($SEARCH_PHRASE; "i"))) | 
    select (.snippet.liveBroadcastContent | test ("none")) | .id'`)
}


# Filters down the search results to a minimal set that matches the filtered video search
function filter_search_results() {

  echo "$ACCT_ID `date` Filtering Search Results" | tee -a $LOGPATH/status.log

  COUNT=0
  SEARCH_URL=""

  FILTERED_VIDEOS=()

  # Uncomment if you want to debug
  rm $DEBUGPATH/raw_specific_video_search_output.txt 2> /dev/null
  
  # Build up search commands and execute search
  for i in "${VIDEOS[@]}"
  do
    if [[ ${#i} -gt 0 ]] ; then
      COUNT=$COUNT+1
      VIDEO_SEARCH_LIST="$VIDEO_SEARCH_LIST$i%2C"

      if ! (( COUNT % 50))
      then
        perform_filtered_video_search
        VIDEO_SEARCH_LIST=""
      fi
    fi
  done

  # Perform final search
  if (( COUNT % 50))
  then
      perform_filtered_video_search
  fi

  # Sort the result
  rm $DATAPATH/video_list.txt 2> /dev/null
  touch $DATAPATH/video_list_tmp.txt
  for i in "${FILTERED_VIDEOS[@]}"
  do
    echo $i >> $DATAPATH/video_list_tmp.txt
  done

  sort $DATAPATH/video_list_tmp.txt | uniq > $DATAPATH/video_list.txt
  rm $DATAPATH/video_list_tmp.txt
}


# Updates the playlist!
function update_playlist {

  echo "$ACCT_ID `date` Updating Playlist" | tee -a $LOGPATH/status.log

  # Get the first page of the playlist
  SEARCH_URL="https://www.googleapis.com/youtube/v3/playlistItems?part=snippet&maxResults=50&playlistId=${PLAYLIST}&key=$GOOGLE_API_KEY"
  RESULT=`curl -s -X GET $SEARCH_URL`
  PLAYLIST_URL_COST=$((PLAYLIST_URL_COST+1))
 
  NEXT_PAGE_PLAYLIST_TOKEN=`echo $RESULT | jq -r '.nextPageToken'`

  # Filter the video IDs from the return results
  VIDEOS_PLAYLIST=(`echo $RESULT | jq -c -r ' .items[].snippet.resourceId.videoId'`)

  # Get subsequent pages of the playlist and filter results accordingly
  while [[ ! $NEXT_PAGE_PLAYLIST_TOKEN == "null" ]]
  do
    CURL_CMD=" $SEARCH_URL&pageToken=$NEXT_PAGE_PLAYLIST_TOKEN"
    RESULT=`curl -s -X GET $CURL_CMD`
    PLAYLIST_URL_COST=$((PLAYLIST_URL_COST+1))
    VIDEOS_PLAYLIST+=(`echo $RESULT | jq -c -r ' .items[].snippet.resourceId.videoId'`)
    NEXT_PAGE_PLAYLIST_TOKEN=`echo $RESULT | jq -r '.nextPageToken'`
  done 

  # Sort the result
  rm $DATAPATH/playlist.txt 2> /dev/null
  touch $DATAPATH/playlist_tmp.txt
  for i in "${VIDEOS_PLAYLIST[@]}"
  do
    echo $i >> $DATAPATH/playlist_tmp.txt
  done

  sort $DATAPATH/playlist_tmp.txt > $DATAPATH/playlist.txt
  rm $DATAPATH/playlist_tmp.txt

  # Determine which videos are in the video list results that are NOT on the playlist
  NEW_VIDEOS=(`comm -23 $DATAPATH/video_list.txt $DATAPATH/playlist.txt`)

  # Get an access token that can be used to modify the playlist  
  GOOGLE_ACCESS_TOKEN=`curl -s \
  --request POST \
  --data "client_id=$GOOGLE_CLIENT_ID&client_secret=$GOOGLE_CLIENT_SECRET&refresh_token=$GOOGLE_REFRESH_TOKEN&grant_type=refresh_token" \
  https://accounts.google.com/o/oauth2/token | jq -r .access_token`

  # Add each new video to the playlist.
  for i in "${NEW_VIDEOS[@]}"
  do
    echo "$ACCT_ID `date` New video added: $i " | tee -a $LOGPATH/playlist_update_history.log
    DATA="{\"snippet\": { \"playlistId\": \"${PLAYLIST}\", \"resourceId\": {\"kind\": \"youtube#video\",\"videoId\": \"${i}\"}}}"
    CURL_RESPONSE=`curl -s -X POST "https://www.googleapis.com/youtube/v3/playlistItems?part=snippet&key=$GOOGLE_API_KEY" \
     -H "Authorization: Bearer $GOOGLE_ACCESS_TOKEN" \
     -H 'Content-Type: application/json' \
     -d "$DATA"`
    PLAYLIST_UPDATE_COST=$((PLAYLIST_UPDATE_COST+50))
    # Uncomment if you wish to debug
    echo $CURL_RESPONSE >> $DEBUGPATH/playlist_addition_history.txt
  done
}


# Outputs Cost Accounting Data to the Status Log
function output_cost_accounting_data {

  echo "$ACCT_ID `date` Hash Search Cost: $HASH_SEARCH_COST" | tee -a $LOGPATH/status.log
  echo "$ACCT_ID `date` Videos Search Cost: $VIDEOS_SEARCH_COST" | tee -a $LOGPATH/status.log
  echo "$ACCT_ID `date` Playlist URL Cost: $PLAYLIST_URL_COST" | tee -a $LOGPATH/status.log
  echo "$ACCT_ID `date` Playlist Update Cost: $PLAYLIST_UPDATE_COST" | tee -a $LOGPATH/status.log
  echo "$ACCT_ID `date` Total Update Cost: $((HASH_SEARCH_COST+VIDEOS_SEARCH_COST+PLAYLIST_URL_COST+PLAYLIST_UPDATE_COST))" | tee -a $LOGPATH/status.log
}


# Initializes any path or global variables that we need for the script
function initialize {

  # Make any paths we need
  mkdir -p $LOGPATH
  mkdir -p $DATAPATH
  mkdir -p $DEBUGPATH

  # Cost of performing each operation
  HASH_SEARCH_COST=0
  VIDEOS_SEARCH_COST=0
  PLAYLIST_URL_COST=0
  PLAYLIST_UPDATE_COST=0

  # Raw video output
  VIDEOS=""

  # Next page token for getting more results
  NEXT_PAGE_TOKEN=""
}


##################
## MAIN EXECUTION
##################

# Initialize any paths and/or variables that we need!
initialize

# Executes a YouTube search based on defined search phrases
execute_search

# Filter the search results and output a file
filter_search_results

# Update the playlist
update_playlist

# Output Cost Accounting Data to the status log
output_cost_accounting_data