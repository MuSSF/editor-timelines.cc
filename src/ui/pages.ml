open Js_utils
open Js_of_ocaml_tyxml.Tyxml_js.Html

type dispatcher = args:(string * string) list -> (unit, unit Xhr_lwt.error) result Lwt.t

let pages : (string, dispatcher) Hashtbl.t = Hashtbl.create 3

let add_page path f = Hashtbl.add pages path f

let main_div_id = "page-content"
let get_main_page () = find_component main_div_id
let set_in_main_page content = Manip.replaceChildren (get_main_page ()) content

let default_page ?(link_name = "Home") ~classes () =
  Ui_utils.a_link
    ~args:[]
    ~path:""
    ~classes:("border" :: classes)
    [txt link_name]

let error_404 ?(msg="Unknown page") ~path ~args () =
  div ~a:[a_class ["center"; "big-block"]] [
    h2 [txt "Error 404"];
    br ();
    txt @@ Format.sprintf "It seems you are lost. %s" msg;
    br ();
    default_page ~classes:["center"] ()
  ]

let finish () = Lwt.return (Ok ())

let dispatch ~path ~args =
  try
    match Hashtbl.find pages path with
    | exception Not_found -> set_in_main_page [error_404 ~path ~args ()]; finish ()
    | f ->
      let url = Ui_utils.url path args in
      Ui_utils.push url;
      f ~args
  with exn ->
    Js_utils.log "Exception in dispatch of %s: %s"
      path
      (Printexc.to_string exn);
    raise exn

let () = Dispatcher.dispatch := dispatch

(* Controllers *)

let login_action log pwd =
  ignore @@
  Request.login log pwd (function
      | Some auth_data -> begin
          Js_utils.log "Login OK!@.";
          Ui_utils.auth_session log auth_data;
          Js_utils.reload ();
          finish ()
        end
      | None -> begin
          Js_utils.alert "Wrong login/password@.";
          finish ()
        end)

let logout_action args =
  ignore @@
  Request.logout
    ~args
    (fun _ ->
       Ui_utils.logout_session ();
       Js_utils.reload ();
       finish ())

let register_action log pwd =
  ignore @@ Request.register_user log pwd (fun _ -> finish ())

let add_action event =
  Js_utils.log "Adding event %a" Utils.pp_event event;
  let args = Ui_utils.get_args () in
  ignore @@
  Request.add_event ~args
    event
    (function
      | Ok () -> dispatch ~path:"" ~args
      | Error s -> Lwt.return (Error (Xhr_lwt.Str_err ("Add new event action failed: " ^ s)))
    )

let main_page ~args =
  Request.timeline_data ~args (fun events ->
      Request.is_auth (fun is_auth ->
          Request.categories (fun categories ->
              let page, init =
                Home.page
                  ~login_action
                  ~register_action
                  ~logout_action
                  ~add_action
                  is_auth args categories events in
              set_in_main_page [page];
              init ();
              finish ()
            )
        )
    )

let admin_page_if_trustworthy ~args =
  let remove_action i =
    let c = Js_utils.confirm "Are you sure you want to remove this event ? This is irreversible." in
    if c then
      ignore @@
      Request.remove_event
        ~args
        i
        (fun _ ->
           ignore @@ !Dispatcher.dispatch ~path:"admin" ~args:[];
           finish ())
    else ()
  in
  let rec update_action i old_event categories = (
    fun new_event ->
      Js_utils.log "Update...";
      ignore @@
      Request.update_event ~args i ~old_event ~new_event (
        function
        | Success -> begin
            Js_utils.log "Going back to main page";
            dispatch
              ~path:Admin.page_name
              ~args:(["action", "edit"])
          end
        | Failed s -> begin
            Js_utils.log "Update failed: %s" s;
            Lwt.return
              (Error (Xhr_lwt.Str_err ("Update event action failed: " ^ s)))
          end
        | Modified event_opt ->
          Js_utils.log "Event has been modified while editing";
          set_in_main_page [
            Admin.compare
              i
              event_opt
              new_event
              categories
              ~add_action
              ~update_action
              ~remove_action
          ];
          finish ()
      )
  ) in
  match List.assoc_opt "action" args with
  | Some "add" ->
    Request.categories (fun categories ->
        let form, get_event =
          Admin.add_new_event_form categories in
        let add_button =
          Ui_utils.simple_button
            (fun () -> add_action (get_event ()))
            "Add new event"
        in
        let back = Admin.back_button () in
        set_in_main_page [form; add_button; back];
        finish ()
      )
  | None | Some "edit" ->
    begin
      match List.assoc_opt "id" args with
      | None ->
        Request.events ~args
          (fun events ->
             set_in_main_page
               (Admin.events_list args
                  ~export_action:(fun () ->
                      Request.events ~args (fun events ->
                          Request.title ~args (fun title ->
                              let sep = "%2C" in
                              let title =
                                match title with
                                | None -> sep
                                | Some title -> Data_encoding.title_to_csv ~sep title in
                              let header = Data_encoding.header ~sep in
                              let events =
                                List.fold_left
                                  (fun acc event ->
                                     acc ^ Data_encoding.event_to_csv ~sep event ^ ";%0A")
                                  ""
                                  (snd @@ List.split events) in
                              let str =  (title ^ ";%0A" ^ header ^ ";%0A" ^ events) in
                              Ui_utils.download "database.csv" str; finish ())))
                  ~logout_action
                  events); finish ())
      | Some i -> begin
          try
            let i = int_of_string i in
            Request.categories (fun categories ->
                Request.event ~args i (fun old_event ->
                    let form, get_event =
                      Admin.event_form
                        old_event
                        i
                        categories
                    in
                    let edit_button =
                      Ui_utils.simple_button
                        (fun () -> update_action i old_event categories (get_event ()))
                        "Update event"
                    in
                    let remove_button =
                      Ui_utils.simple_button
                        (fun () -> remove_action i)
                        "Remove event"
                    in
                    let back = Admin.back_button () in
                    set_in_main_page [form; edit_button; remove_button; back];
                    finish ())
              )
          with
            Invalid_argument _ ->
            let msg = Format.sprintf "Invalid event id %s" i in
            set_in_main_page [error_404 ~msg ~path:Admin.page_name ~args ()]; finish ()
        end
    end
  | Some _ -> set_in_main_page [error_404 ~path:Admin.page_name ~args ()]; finish ()

let admin_page_if_not_trustworthy () =
  set_in_main_page [
    Admin.admin_page_login
      ~login_action
      ~register_action
  ];
  finish ()

let admin_page ~args =
  Request.is_auth (fun logged ->
      Js_utils.log "Logged ? %b" logged;
      if logged then
        admin_page_if_trustworthy ~args
      else
        admin_page_if_not_trustworthy ()
    )

let () =
  add_page ""              main_page;
  add_page Home.page_name  main_page;
  add_page Admin.page_name admin_page
