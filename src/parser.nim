import json, strutils, options, tables, times, math
import types, parserutils

proc parseProfile(js: JsonNode; id=""): Profile =
  if js == nil: return
  result = Profile(
    id: if id.len > 0: id else: js{"id_str"}.getStr,
    username: js{"screen_name"}.getStr,
    fullname: js{"name"}.getStr,
    location: js{"location"}.getStr,
    bio: js{"description"}.getStr,
    userpic: js{"profile_image_url_https"}.getStr.replace("_normal", ""),
    banner: js.getBanner,
    following: $js{"friends_count"}.getInt,
    followers: $js{"followers_count"}.getInt,
    tweets: $js{"statuses_count"}.getInt,
    likes: $js{"favourites_count"}.getInt,
    media: $js{"media_count"}.getInt,
    verified: js{"verified"}.getBool,
    protected: js{"protected"}.getBool,
    joinDate: js{"created_at"}.getTime
  )

  result.expandProfileEntities(js)

proc parseGraphProfile*(js: JsonNode; username: string): Profile =
  with errors, js{"errors"}:
    for error in errors:
      case Error(error{"code"}.getInt)
      of notFound: return Profile(username: username)
      of suspended: return Profile(username: username, suspended: true)
      else: discard

  let user = js{"data", "user", "legacy"}
  let id = js{"data", "user", "rest_id"}.getStr
  parseProfile(user, id)

proc parseGraphList*(js: JsonNode): List =
  if js == nil: return

  var list = js{"data", "user_by_screen_name", "list"}
  if list == nil:
    list = js{"data", "list"}
  if list == nil:
    return

  result = List(
    id: list{"id_str"}.getStr,
    name: list{"name"}.getStr,
    username: list{"user", "legacy", "screen_name"}.getStr,
    userId: list{"user", "legacy", "id_str"}.getStr,
    description: list{"description"}.getStr,
    members: list{"member_count"}.getInt,
    banner: list{"custom_banner_media", "media_info", "url"}.getStr
  )

proc parseListMembers*(js: JsonNode; cursor: string): Result[Profile] =
  result = Result[Profile](
    beginning: cursor.len == 0,
    query: Query(kind: userList)
  )

  if js == nil: return

  result.top = js{"previous_cursor_str"}.getStr
  result.bottom = js{"next_cursor_str"}.getStr
  if result.bottom.len == 1:
    result.bottom.setLen 0

  for u in js{"users"}:
    result.content.add parseProfile(u)

proc parsePoll(js: JsonNode): Poll =
  let vals = js{"binding_values"}
  # name format is pollNchoice_*
  for i in '1' .. js{"name"}.getStr[4]:
    let choice = "choice" & i
    result.values.add parseInt(vals{choice & "_count"}.getStrVal("0"))
    result.options.add vals{choice & "_label"}.getStrVal

  let time = vals{"end_datetime_utc", "string_value"}.getDateTime
  if time > getTime():
    let timeLeft = $(time - getTime())
    result.status = timeLeft[0 ..< timeLeft.find(",")]
  else:
    result.status = "Final results"

  result.leader = result.values.find(max(result.values))
  result.votes = result.values.sum

proc parseGif(js: JsonNode): Gif =
  Gif(
    url: js{"video_info", "variants"}[0]{"url"}.getStr,
    thumb: js{"media_url_https"}.getStr
  )

proc parseVideo(js: JsonNode): Video =
  result = Video(
    videoId: js{"id_str"}.getStr,
    thumb: js{"media_url_https"}.getStr,
    views: js{"ext", "mediaStats", "r", "ok", "viewCount"}.getStr,
    available: js{"ext_media_availability", "status"}.getStr == "available",
    title: js{"ext_alt_text"}.getStr,
    durationMs: js{"duration_millis"}.getInt
  )

  for v in js{"video_info", "variants"}:
    result.variants.add VideoVariant(
      videoType: v{"content_type"}.to(VideoType),
      bitrate: v{"bitrate"}.getInt,
      url: v{"url"}.getStr
    )

proc parsePromoVideo(js: JsonNode): Video =
  result = Video(
    videoId: js{"player_content_id"}.getStrVal(js{"card_id"}.getStrVal),
    thumb: js{"player_image_large", "image_value", "url"}.getStr,
    available: true,
    durationMs: js{"content_duration_seconds"}.getStrVal("0").parseInt * 1000,
  )

  var variant = VideoVariant(
    videoType: m3u8,
    url: js{"player_hls_url"}.getStrVal(js{"player_stream_url"}.getStrVal)
  )

  if "vmap" in variant.url:
    variant.videoType = vmap

  result.playbackType = vmap
  result.variants.add variant

proc parseBroadcast(js: JsonNode): Card =
  let image = js{"broadcast_thumbnail_large", "image_value", "url"}.getStr
  result = Card(
    kind: broadcast,
    url: js{"broadcast_url"}.getStrVal,
    title: js{"broadcaster_display_name"}.getStrVal,
    text: js{"broadcast_title"}.getStrVal,
    image: image,
    video: some Video(videoId: js{"broadcast_media_id"}.getStrVal, thumb: image)
  )

proc parseCard(js: JsonNode; urls: JsonNode): Card =
  const imageTypes = ["photo_image_full_size", "summary_photo_image",
                      "thumbnail_image", "promo_image", "player_image"]
  let
    vals = ? js{"binding_values"}
    name = js{"name"}.getStr
    kind = parseEnum[CardKind](name[(name.find(":") + 1) ..< name.len])

  result = Card(
    kind: kind,
    url: vals.getCardUrl(kind),
    dest: vals.getCardDomain(kind),
    title: vals.getCardTitle(kind),
    text: vals{"description"}.getStrVal
  )

  if result.url.len == 0:
    result.url = js{"url"}.getStr

  case kind
  of promoVideo, promoVideoConvo:
    result.video = some parsePromoVideo(vals)
  of broadcast:
    result = parseBroadcast(vals)
  of player:
    result.url = vals{"player_url"}.getStrVal
    if "youtube.com" in result.url:
      result.url = result.url.replace("/embed/", "/watch?v=")
  else: discard

  for typ in imageTypes:
    with img, vals{typ & "_large"}:
      result.image = img{"image_value", "url"}.getStr
      break

  for u in ? urls:
    if u{"url"}.getStr == result.url:
      result.url = u{"expanded_url"}.getStr
      break

proc parseTweet(js: JsonNode): Tweet =
  if js == nil: return
  result = Tweet(
    id: js{"id_str"}.getId,
    threadId: js{"conversation_id_str"}.getId,
    replyId: js{"in_reply_to_status_id_str"}.getId,
    text: js{"full_text"}.getStr,
    time: js{"created_at"}.getTime,
    hasThread: js{"self_thread"} != nil,
    available: true,
    profile: Profile(id: js{"user_id_str"}.getStr),
    stats: TweetStats(
      replies: js{"reply_count"}.getInt,
      retweets: js{"retweet_count"}.getInt,
      likes: js{"favorite_count"}.getInt,
    )
  )

  result.expandTweetEntities(js)

  if js{"is_quote_status"}.getBool:
    result.quote = some Tweet(id: js{"quoted_status_id_str"}.getId)

  with rt, js{"retweeted_status_id_str"}:
    result.retweet = some Tweet(id: rt.getId)
    return

  with jsCard, js{"card"}:
    let name = jsCard{"name"}.getStr
    if "poll" in name:
      if "image" in name:
        result.photos.add jsCard{"binding_values", "image_large", "image_value", "url"}.getStr

      result.poll = some parsePoll(jsCard)
    else:
      result.card = some parseCard(jsCard, js{"entities", "urls"})

  with jsMedia, js{"extended_entities", "media"}:
    for m in jsMedia:
      case m{"type"}.getStr
      of "photo":
        result.photos.add m{"media_url_https"}.getStr
      of "video":
        result.video = some(parseVideo(m))
      of "animated_gif":
        result.gif = some(parseGif(m))
      else: discard

proc finalizeTweet(global: GlobalObjects; id: string): Tweet =
  let intId = if id.len > 0: parseInt(id) else: 0
  result = global.tweets.getOrDefault(id, Tweet(id: intId))

  if result.quote.isSome:
    let quote = get(result.quote).id
    if $quote in global.tweets:
      result.quote = some global.tweets[$quote]
    else:
      result.quote = some Tweet()

  if result.retweet.isSome:
    let rt = get(result.retweet).id
    if $rt in global.tweets:
      result.retweet = some finalizeTweet(global, $rt)
    else:
      result.retweet = some Tweet()

proc parsePin(js: JsonNode; global: GlobalObjects): Tweet =
  let pin = js{"pinEntry", "entry", "entryId"}.getStr
  if pin.len == 0: return

  let id = pin.getId
  if id notin global.tweets: return

  global.tweets[id].pinned = true
  return finalizeTweet(global, id)

proc parseGlobalObjects(js: JsonNode): GlobalObjects =
  result = GlobalObjects()
  let
    tweets = ? js{"globalObjects", "tweets"}
    users = ? js{"globalObjects", "users"}

  for k, v in users:
    result.users[k] = parseProfile(v, k)

  for k, v in tweets:
    var tweet = parseTweet(v)
    if tweet.profile.id in result.users:
      tweet.profile = result.users[tweet.profile.id]
    result.tweets[k] = tweet

proc parseThread(js: JsonNode; global: GlobalObjects): tuple[thread: Chain, self: bool] =
  result.thread = Chain()
  for t in js{"content", "timelineModule", "items"}:
    let content = t{"item", "content"}
    if "Self" in content{"tweet", "displayType"}.getStr:
      result.self = true

    let entry = t{"entryId"}.getStr
    if "show_more" in entry:
      let
        cursor = content{"timelineCursor"}
        more = cursor{"displayTreatment", "actionText"}.getStr
      result.thread.more = parseInt(more[0 ..< more.find(" ")])
      result.thread.cursor = cursor{"value"}.getStr
    else:
      var tweet = finalizeTweet(global, entry.getId)
      if not tweet.available:
        tweet.tombstone = getTombstone(content{"tombstone"})
      result.thread.content.add tweet

proc parseConversation*(js: JsonNode; tweetId: string): Conversation =
  result = Conversation(replies: Result[Chain](beginning: true))
  let global = parseGlobalObjects(? js)

  let instructions = ? js{"timeline", "instructions"}
  for e in instructions[0]{"addEntries", "entries"}:
    let entry = e{"entryId"}.getStr
    if "tweet" in entry:
      let tweet = finalizeTweet(global, entry.getId)
      if $tweet.id != tweetId:
        result.before.content.add tweet
      else:
        result.tweet = tweet
    elif "conversationThread" in entry:
      let (thread, self) = parseThread(e, global)
      if thread.content.len > 0:
        if self:
          result.after = thread
        else:
          result.replies.content.add thread
    elif "cursor-showMore" in entry:
      result.replies.bottom = e.getCursor
    elif "cursor-bottom" in entry:
      result.replies.bottom = e.getCursor

proc parseUsers*(js: JsonNode; after=""): Result[Profile] =
  result = Result[Profile](beginning: after.len == 0)
  let global = parseGlobalObjects(? js)

  let instructions = ? js{"timeline", "instructions"}
  for e in instructions[0]{"addEntries", "entries"}:
    let entry = e{"entryId"}.getStr
    if "sq-I-u" in entry:
      let id = entry.getId
      if id in global.users:
        result.content.add global.users[id]
    elif "cursor-top" in entry:
      result.top = e.getCursor
    elif "cursor-bottom" in entry:
      result.bottom = e.getCursor

proc parseTimeline*(js: JsonNode; after=""): Timeline =
  result = Timeline(beginning: after.len == 0)
  let global = parseGlobalObjects(? js)

  let instructions = ? js{"timeline", "instructions"}
  if instructions.len == 0: return

  for i in instructions:
    if result.beginning and i{"pinEntry"} != nil:
      with pin, parsePin(i, global):
        result.content.add pin
    else:
      # This is necessary for search
      with r, i{"replaceEntry", "entry"}:
        if "top" in r{"entryId"}.getStr:
          result.top = r.getCursor
        elif "bottom" in r{"entryId"}.getStr:
          result.bottom = r.getCursor

  for e in instructions[0]{"addEntries", "entries"}:
    let entry = e{"entryId"}.getStr
    if "tweet" in entry or "sq-I-t" in entry:
      let tweet = finalizeTweet(global, entry.getId)
      if not tweet.available: continue
      result.content.add tweet
    elif "cursor-top" in entry:
      result.top = e.getCursor
    elif "cursor-bottom" in entry:
      result.bottom = e.getCursor

proc parsePhotoRail*(tl: Timeline): PhotoRail =
  for tweet in tl.content:
    if result.len == 16: break

    let url = if tweet.photos.len > 0: tweet.photos[0]
              elif tweet.video.isSome: get(tweet.video).thumb
              elif tweet.gif.isSome: get(tweet.gif).thumb
              elif tweet.card.isSome: get(tweet.card).image
              else: ""

    if url.len == 0:
      continue

    result.add GalleryPhoto(
      url: url,
      tweetId: $tweet.id,
      color: "#161616"
    )
