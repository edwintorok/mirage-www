open Printf

open Lwt.Infix

module Main
    (C: V1_LWT.CONSOLE) (FS: V1_LWT.KV_RO) (TMPL: V1_LWT.KV_RO)
    (S: Cohttp_lwt.Server)
= struct

  let log c fmt = Printf.kprintf (C.log c) fmt
  let err fmt = Printf.kprintf (fun f -> raise (Failure f)) fmt
  let err_not_found name = err "%s not found" name

  let read_tmpl tmpl name =
    TMPL.size tmpl name >>= function
    | `Error (TMPL.Unknown_key _) -> err_not_found name
    | `Ok size ->
      TMPL.read tmpl name 0 (Int64.to_int size) >>= function
      | `Error (TMPL.Unknown_key _) -> err_not_found name
      | `Ok bufs -> Lwt.return (Cstruct.copyv bufs)

  let read_fs fs name =
    FS.size fs name >>= function
    | `Error (FS.Unknown_key _) -> err_not_found name
    | `Ok size ->
      FS.read fs name 0 (Int64.to_int size) >>= function
      | `Error (FS.Unknown_key _) -> err_not_found name
      | `Ok bufs -> Lwt.return (Cstruct.copyv bufs)

  let read_entry tmpl name = read_tmpl tmpl name >|= Cow.Markdown.of_string

  let respond_ok ?(headers=[]) body =
    body >>= fun body ->
    let status = `OK in
    let headers = Cohttp.Header.of_list headers in
    S.respond_string ~headers ~status ~body ()

  let not_found page = Lwt.return (`Not_found page)
  let html h = Lwt.return (`Html h)
  let page p path = p >|= fun f -> (`Page (f path))
  let redirect r = Lwt.return (`Redirect r)

  let blog_feed s tmpl = Site_config.blog s (fun n -> read_entry tmpl ("/blog/"^n))
  let wiki_feed s tmpl = Site_config.wiki s (fun n -> read_entry tmpl ("/wiki/"^n))
  let updates_feed s tmpl = Site_config.updates s (read_entry tmpl)
  let links_feed s tmpl = Site_config.links s (read_entry tmpl)

  let updates_feeds s tmpl = [
    `Blog (blog_feed s tmpl, Data.Blog.entries);
    `Wiki (wiki_feed s tmpl, Data.Wiki.entries);
  ]

  let blog_dispatch s tmpl = Blog.dispatch (blog_feed s tmpl) Data.Blog.entries
  let wiki_dispatch s tmpl = Wiki.dispatch (wiki_feed s tmpl) Data.Wiki.entries
  let releases_dispatch tmpl = Pages.Releases.dispatch (read_tmpl tmpl)
  let links_dispatch s tmpl = Pages.Links.dispatch (links_feed s tmpl) Data.Links.entries
  let updates_dispatch s tmpl =
    Pages.Index.dispatch ~feed:(updates_feed s tmpl) ~feeds:(updates_feeds s tmpl)

  let stats () = html (Lwt.return (Cow.Html.to_string (Stats.page ())))
  let redirect_notes () = redirect "../wiki#Weeklycallsandreleasenotes"
  let index s tmpl = html (Pages.Index.t ~feeds:(updates_feeds s tmpl) (read_tmpl tmpl))
  let about tmpl = html (Pages.About.t (read_tmpl tmpl))

  let asset c fs path =
    let path = String.concat "/" path in
    let asset path = Lwt.return (`Asset (read_fs fs path)) in
    Lwt.catch (fun () -> asset path) (fun e  -> not_found path)

  (* dispatch non-file URLs *)
  let dispatcher s c fs tmpl = function
    | [] | [""] | ["index.html"] -> index s tmpl
    | ["stats"; "gc"] -> stats ()
    | ["about"] | ["community"] -> about tmpl
    | "releases" :: tl -> page (releases_dispatch tmpl) tl
    | "blog"     :: tl -> page (blog_dispatch s tmpl) tl
    | "links"    :: tl -> links_dispatch s tmpl >|= fun f -> f tl
    | "updates"  :: tl -> page (updates_dispatch s tmpl) tl
    | ("wiki" | "docs") :: "weekly" :: tl -> redirect_notes ()
    | "docs" :: tl | "wiki" :: tl -> page (wiki_dispatch s tmpl) tl
    | path -> asset c fs path

  let create c dispatch =
    let callback conn_id request body =
      let uri = Cohttp.Request.uri request in
      let io = {
        Cowabloga.Dispatch.log = (fun ~msg -> C.log c msg);
        ok = respond_ok;
        notfound = (fun ~uri -> S.respond_not_found ~uri ());
        redirect = (fun ~uri -> S.respond_redirect ~uri ());
      } in
      Cowabloga.Dispatch.f io dispatch uri
    in
    let conn_closed (_,conn_id) =
      let cid = Cohttp.Connection.to_string conn_id in
      C.log c (Printf.sprintf "conn %s closed" cid)
    in
    Stats.start OS.Time.sleep;
    S.make ~callback ~conn_closed ()

  let start c fs tmpl http =
    http (`TCP 80) (create c (dispatcher `Http c fs tmpl))

end
