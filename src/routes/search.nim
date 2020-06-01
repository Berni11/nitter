import strutils, sequtils, uri

import jester

import router_utils
import ".."/[query, types, api]
import ../views/[general, search]

include "../views/opensearch.nimf"

export search

proc createSearchRouter*(cfg: Config) =
  router search:
    get "/search/?":
      if @"q".len > 200:
        resp Http400, showError("Search input too long.", cfg)

      let prefs = cookiePrefs()
      let query = initQuery(params(request))

      case query.kind
      of users:
        if "," in @"q":
          redirect("/" & @"q")
        let users = await getSearch[Profile](query, getCursor())
        resp renderMain(renderUserSearch(users, prefs), request, cfg)
      of tweets:
        let tweets = await getSearch[Tweet](query, getCursor())
        let rss = "/search/rss?" & genQueryUrl(query)
        resp renderMain(renderTweetSearch(tweets, prefs, getPath()),
                        request, cfg, rss=rss)
      else:
        resp Http404, showError("Invalid search", cfg)

    get "/hashtag/@hash":
      redirect("/search?q=" & encodeUrl("#" & @"hash"))

    get "/opensearch":
      var url = ""
      if cfg.useHttps:
        url = "https://" & cfg.hostname & "/search?q="
      else:
        url = "http://" & cfg.hostname & "/search?q="
      resp Http200, {"Content-Type": "application/opensearchdescription+xml"},
                    generateOpenSearchXML(cfg.title, cfg.hostname, url)
