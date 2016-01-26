open Utility
open Type;;

(* TODO: Wrapper types around pixel height / width vs character height / width *)

Graphics.open_graph "";;
Graphics.auto_synchronize false;;
Graphics.set_font "Lucida Console";;
let (text_width, text_height) = Graphics.text_size "X";;

let draw_string_at text x y =
  Graphics.moveto x y;
  Graphics.draw_string text;;

type state =
  | Paused
  | Running
  | Halted
  | Stepping of instruction_address

type action =
  | Pause
  | StepBackwards
  | StepForwards
  | Run
  | Quit
  | Keystroke of char
  | NoAction

type t =
{
  undo_stack : Interpreter.t list;
  redo_stack : Interpreter.t list;
  interpreter : Interpreter.t;
  state : state;
  keystrokes : string;
  buttons :  (Button.t * action) list;
}

(* Extra line for status *)
let screen_extent screen =
  let w = Screen.width screen in
  let h = Screen.height screen in
  (10, 10, w * text_width, (h + 1) * text_height);;

let make interpreter =
  let screen = Interpreter.screen interpreter in
  let (x, y, _, h) = screen_extent screen in
  let margin = 20 in
  let gap = 10 in
  let button_y = y + h + gap in
  let button_list =
    [
      ("X", Quit);
      ("<|", StepBackwards);
      ("||", Pause);
      (">", Run);
      ("|>", StepForwards)
    ] in
    let button_map =
      let rec aux map buttons button_x =
        match buttons with
        | [] -> map
        | (caption, action) :: tail ->
          let new_button = Button.make button_x button_y margin caption in
          let new_x = button_x + new_button.Button.width + gap in
          aux ((new_button, action) :: map) tail new_x in
      aux [] button_list x in
  {
    undo_stack = [];
    redo_stack = [];
    interpreter = interpreter;
    state = Running;
    keystrokes = "";
    buttons = button_map
  }

let clear_screen screen =
  let (x, y, w, h) = screen_extent screen in
  Graphics.set_color Graphics.background;
  Graphics.fill_rect x y w h

let draw_status screen =
  let (x, y, _, _) = screen_extent screen in
  let status_color = Graphics.blue in
  match Screen.status screen with
  | Status None  -> ()
  | Status Some status -> (
    Graphics.set_color status_color;
    let h = Screen.height screen in
    draw_string_at status x (y + text_height * h) )

let rec draw_screen screen =
  clear_screen screen;
  draw_status screen;
  Graphics.set_color Graphics.foreground;
  let (x, y, _, _) = screen_extent screen in
  let rec aux n =
    let h = Screen.height screen in
    if n < h then (
      let text = Deque.peek_front_at (Screen.lines screen) n in
      let text_y = y + text_height * n in
      draw_string_at text x text_y;
      aux (n + 1)) in
  aux 0 ;
  Graphics.synchronize()

let trim_to_length text length =
  if (String.length text) <= length then text
  else String.sub text 0 length

(* x and y in screen coordinates; width and height in characters *)
let draw_before_current_after before current after x y width height =
  let before_color = Graphics.blue in
  let current_color = Graphics.black in
  let after_color = Graphics.blue in
  let rec draw_before items n =
    if n < height then
      match items with
      | [] -> ()
      | text :: tail -> (
        draw_string_at text x (y + n * text_height);
        draw_before tail (n + 1)) in
  let rec draw_after items n =
    if n > 0 then
      match items with
      | [] -> ()
      | text :: tail -> (
        draw_string_at text x (y + n * text_height);
        draw_after tail (n - 1)) in
  Graphics.set_color Graphics.background;
  Graphics.fill_rect x y (width * text_width) (height * text_height);
  Graphics.set_color before_color;
  draw_before before (height / 2 + 1);
  Graphics.set_color current_color;
  draw_string_at current x (y + text_height * (height / 2));
  Graphics.set_color after_color;
  draw_after after (height / 2 - 1);
  Graphics.set_color Graphics.foreground;
  Graphics.synchronize();;

(* TODO: use draw_before_current_after *)
let draw_undo_redo debugger =
  let undo_color = Graphics.blue in
  let redo_color = Graphics.blue in
  let current_color = Graphics.black in
  let interpreter = debugger.interpreter in
  let screen = Interpreter.screen interpreter in
  let (screen_x, screen_y, screen_w, screen_h) = screen_extent screen in
  let window_x = screen_x + screen_w + 10 in
  let window_y = screen_y in
  let instruction_width = 60 in
  let window_w = text_width * instruction_width in
  let window_h = text_height * (Screen.height screen) in
  let draw_line interp n =
    let instr = Interpreter.display_current_instruction interp in
    let text = trim_to_length instr instruction_width in
    draw_string_at text window_x (window_y + text_height * n) in
  let rec draw_undo undo n =
    if n < (Screen.height screen) then
      match undo with
      | [] -> ()
      | h :: t -> (
        draw_line h n;
        draw_undo t (n + 1)) in
  let rec draw_redo redo n =
    if n > 0 then
      match redo with
      | [] -> ()
      | h :: t -> (
        draw_line h n;
        draw_redo t (n - 1)) in
  Graphics.set_color Graphics.background;
  Graphics.fill_rect window_x window_y window_w window_h;
  Graphics.set_color undo_color;
  let h = Screen.height screen in
  draw_undo debugger.undo_stack ( h / 2 + 1);
  Graphics.set_color current_color;
  draw_line debugger.interpreter (h / 2);
  Graphics.set_color redo_color;
  draw_redo debugger.redo_stack (h / 2 - 1);
  Graphics.set_color Graphics.foreground;
  Graphics.synchronize()

let debugger_push_undo debugger new_interpreter =
  let new_pc = Interpreter.program_counter new_interpreter in
  let old_pc = Interpreter.program_counter debugger.interpreter in
  if new_pc = old_pc then
    { debugger with interpreter = new_interpreter; redo_stack = [] }
  else
    { debugger with interpreter = new_interpreter;
      undo_stack = debugger.interpreter :: debugger.undo_stack;
      redo_stack = [] }

let needs_more debugger =
  let screen = Interpreter.screen debugger.interpreter in
  Screen.needs_more screen

let has_keystrokes debugger =
  (String.length debugger.keystrokes) > 0

let draw_interpreter debugger =
  let interpreter = debugger.interpreter in
  let screen = Interpreter.screen interpreter in
  let state = Interpreter.state interpreter in
  let input = Interpreter.input interpreter in
  let has_new_output = Interpreter.has_new_output interpreter in
  if state = Interpreter.Waiting_for_input then
    draw_screen (Screen.fully_scroll (Screen.print screen input))
  else if has_new_output || (debugger.state = Paused) || (debugger.state = Halted) then
    let screen_to_draw =
      if needs_more debugger then
        Screen.more screen
      else
        screen in
    draw_screen screen_to_draw

let step_reverse debugger =
  match debugger.undo_stack with
  | [] -> debugger
  | h :: t -> { debugger with
    undo_stack = t;
    interpreter = h;
    redo_stack = debugger.interpreter :: debugger.redo_stack };;

let step_forward debugger =
  match debugger.redo_stack with
  | h :: t -> { debugger with
    undo_stack = debugger.interpreter :: debugger.undo_stack;
    interpreter = h;
    redo_stack = t }
  | [] ->
    let interpreter = debugger.interpreter in
    let state = Interpreter.state interpreter in
    match state with
    | Interpreter.Waiting_for_input ->
      (* If we have pending keystrokes then take the first one off the queue
      and give it to the interpreter. Otherwise just put this on the undo
      stack and return to the caller otherwise unchanged. We can't progress
      until someone gives us a key. *)
      let (new_interpreter, new_keys) =
        if debugger.keystrokes = "" then
          (interpreter, debugger.keystrokes)
        else
          (Interpreter.step_with_input interpreter debugger.keystrokes.[0],
          String.sub debugger.keystrokes 1 ((String.length debugger.keystrokes) - 1)) in
      { (debugger_push_undo debugger new_interpreter) with keystrokes = new_keys }
    | Interpreter.Halted -> debugger (* TODO: Exception? *)
    | Interpreter.Running ->
      let new_interpreter = Interpreter.step interpreter in
      debugger_push_undo debugger new_interpreter;;

let waiting_for_input debugger =
  (Interpreter.state debugger.interpreter) = Interpreter.Waiting_for_input

let rec obtain_action debugger should_block =
  (* A keystroke observed with Poll is not removed from the queue
  of keystrokes! It will keep coming back every time we poll. We
  therefore only consider keystroke events as having happened
  when we are blocking while waiting for input. *)
  let events =
    if should_block then [Graphics.Key_pressed; Graphics.Button_down]
    else [Graphics.Poll] in
  let status = Graphics.wait_next_event events in
  if should_block && status.Graphics.keypressed then
    Keystroke status.Graphics.key
  else
    let action =
      let is_hit (button, _) =
        Button.was_clicked button status.Graphics.mouse_x status.Graphics.mouse_y in
      if status.Graphics.button then
        match List.filter is_hit debugger.buttons with
        | [] -> NoAction
        | (_, action) :: _ -> action
      else
        NoAction in
    if action = NoAction && should_block then
      (* If we're blocking until something happens, do not report NoAction. *)
      obtain_action debugger should_block
    else
      action

let pause debugger =
  { debugger with state = Paused }

let start_running debugger =
  { debugger with state = Running }

let clear_redo debugger =
  { debugger with redo_stack = [] }

let add_keystroke debugger key =
 { debugger with keystrokes = debugger.keystrokes ^ (string_of_char key) }

let remove_keystroke debugger =
  let k = debugger.keystrokes in
  { debugger with keystrokes = String.sub k 1 ((String.length k) - 1) }

let set_step_instruction debugger instruction =
  { debugger with state = Stepping instruction }

let maybe_step debugger =
  let should_step =
    match debugger.state with
    | Running -> true
    | Stepping instruction ->
      (Interpreter.program_counter debugger.interpreter) = instruction
    | _ -> false in
  if should_step then step_forward debugger
  else debugger

let halt debugger =
  { debugger with state = Halted }

  let draw_routine_listing debugger =
    let current_instruction = Interpreter.program_counter debugger.interpreter in
    (* This can be zero if we were restored from a save game *)
    let frame = Interpreter.current_frame debugger.interpreter in
    (* TODO: as a fallback we can find the transitive closure of routines and
    then see if this instruction is in any of them. *)
    let frame_instruction = Frame.called frame in
    let first_instruction =
      if frame_instruction = Instruction 0 then current_instruction
      else frame_instruction in
    let story = Interpreter.story debugger.interpreter in
    let instr = Instruction.decode story current_instruction in
    let current = Instruction.display instr (Story.version story) in
    let reachable = Reachability.all_reachable_addresses_in_routine story first_instruction in
    let sorted = List.sort compare reachable in
    let decode instr =
      (instr, Instruction.display (Instruction.decode story instr) (Story.version story)) in
    let map = List.map decode sorted in
    let rec aux before after map =
      match map with
      | [] -> (before, after)
      | (addr, text) :: tail ->
        if addr < current_instruction then aux (text :: before) after tail
        else if addr > current_instruction then aux before (text :: after) tail
        else aux before after tail in
    let (before, after) = aux [] [] map in
    let screen = Interpreter.screen debugger.interpreter in
    let (screen_x, screen_y, screen_w, screen_h) = screen_extent screen in
    let x = screen_x + screen_w + 10 in
    draw_before_current_after before current (List.rev after) x screen_y 60 (Screen.height screen)

(* TODO: Most of the methods in this module can be local to run *)

let run debugger =
  let rec main_loop debugger =
    (* Put the debugger into the right state, depending on the interpreter *)
    let interp_state = Interpreter.state debugger.interpreter in
    let debugger =
      match (debugger.state, interp_state) with
      | (_, Interpreter.Halted) -> halt debugger
      | (Stepping instruction, _) ->
        let pc = Interpreter.program_counter debugger.interpreter in
        if pc = instruction then debugger
        else pause debugger
      | _ -> debugger in

    (* Under what circumstances do we need to block?
       1 if the debugger is not running then block
       2 if the debugger is running, has no queued input, and is waiting for input, then block
       3 if the debugger is running, has no queued input, and is waiting for --MORE--, then block
    *)
    let running =
      match debugger.state with
      | Halted
      | Paused -> false
      | _ -> true in

    let needs_more = needs_more debugger in
    let waiting_for_input = waiting_for_input debugger in
    let has_keystrokes = has_keystrokes debugger in
    let should_block = (not running) || ((not has_keystrokes) && (waiting_for_input || needs_more)) in
    draw_interpreter debugger;
    if should_block then draw_routine_listing debugger;
    let action = obtain_action debugger should_block in
    match action with
    | Pause -> main_loop (pause debugger)
    | StepBackwards -> main_loop (pause (step_reverse debugger))
    | StepForwards ->
      let pc = Interpreter.program_counter debugger.interpreter in
      let with_step = set_step_instruction debugger pc in
      main_loop with_step
    | Run -> main_loop (start_running (clear_redo debugger))
    | Quit -> ()
    | Keystroke key -> main_loop (add_keystroke debugger key)
    | NoAction ->
      (* Suppose we blocked because we had --MORE-- but no queued keystrokes.
      If we then got here we must have queued up a keystroke, which is still
      in the queue. The step will clear out the needs_more, but we need to
      lose that keystroke *)
      let new_debugger =
        if needs_more && has_keystrokes then remove_keystroke debugger
        else debugger in
      main_loop (maybe_step new_debugger) in
    List.iter (fun (b, _) -> Button.draw b) debugger.buttons;
    main_loop debugger
