extends CanvasLayer
## The sign-in screen, owned by the ENGINE so a game never writes auth code.
##
## WHEN IT APPEARS — driven entirely by the world, never by the player's patience:
##   "multiplayer": {"enabled": true}   -> required (peers must be identifiable)
##   "auth": true                       -> required (cloud/cross-device saves)
##   neither                            -> NEVER SHOWN. A single-player game gets no login wall,
##                                         its saves are local, and it needs no backend at all.
##
## This is a HARD gate by design: a game that needs identity cannot meaningfully start without it.
## The cost is real — a shared link shows this before a friend can join — so it is two fields, it
## remembers you afterwards (Auth.restore_session), and it never asks twice on the same device.

signal passed()

var _email: LineEdit
var _password: LineEdit
var _status: Label
var _primary: Button
var _toggle: Button
var _busy := false
var _mode_signup := false

## Hold-to-paste. 0.5s is the platform long-press everyone's thumb already expects; the slop is
## generous because a finger is never still.
const HOLD_S := 0.5
const HOLD_SLOP_PX := 14.0
var _hold_le: LineEdit = null
var _hold_at := 0.0
var _hold_from := Vector2.ZERO


## The reveal toggle's icon, DRAWN rather than typed.
##
## The obvious version is a Button with "👁" on it, and it renders as an empty box: the engine's
## bundled font carries no emoji, and this screen is the last place to find that out. Twelve lines of
## _draw() render identically on every device and at every scale.
class EyeIcon extends Control:
	var closed := true
	func _draw() -> void:
		var ctr := size * 0.5
		var r := minf(size.x, size.y) * 0.30
		var col := Color(1, 1, 1, 0.5 if closed else 0.9)
		draw_arc(ctr, r, 0.0, TAU, 20, col, 1.6, true)     # iris
		draw_circle(ctr, r * 0.42, col)                     # pupil
		if closed:
			draw_line(ctr + Vector2(-r * 1.4, r * 1.4), ctr + Vector2(r * 1.4, -r * 1.4), col, 1.6, true)


func _ready() -> void:
	layer = 90   # above the game, below any fade/transition the shell owns
	_build()
	Auth.auth_failed.connect(_on_failed)


## Returns true when the player is (or becomes) signed in. Awaits the screen when one is needed.
func gate(world: Dictionary) -> bool:
	if not Self_required(world):
		queue_free()
		return true

	# Silent path first: a returning player must not be asked again. This is the difference between
	# "an account" and "a login screen every time you play".
	if await Auth.restore_session():
		print("GOGI_AUTH restored existing session — no prompt")
		queue_free()
		return true

	visible = true
	await passed
	queue_free()
	return true


## Multiplayer implies identity; `auth: true` states it outright.
static func Self_required(world: Dictionary) -> bool:
	if bool(world.get("auth", false)):
		return true
	var mp: Variant = world.get("multiplayer", null)
	return mp is Dictionary and bool((mp as Dictionary).get("enabled", false))


func _build() -> void:
	visible = false
	var bg := ColorRect.new()
	bg.color = Color(0.04, 0.05, 0.07, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	# STOP (the default) is load-bearing twice over: it keeps taps from reaching the game behind a
	# modal gate, and it is what lets the background hear the tap that dismisses the keyboard.
	bg.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed:
			_dismiss_keyboard())
	add_child(bg)

	var box := VBoxContainer.new()
	# The form column must not swallow taps aimed at the backdrop — only the fields and buttons
	# inside it should consume input, so a tap in the gaps between them still closes the keyboard.
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.custom_minimum_size = Vector2(320, 0)
	box.add_theme_constant_override("separation", 12)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	bg.add_child(box)

	var title := Label.new()
	title.text = "Sign in to play"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	box.add_child(title)

	var why := Label.new()
	why.text = "This game saves your progress and plays with others."
	why.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	why.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	why.modulate = Color(1, 1, 1, 0.6)
	box.add_child(why)

	_email = LineEdit.new()
	_email.placeholder_text = "email"
	# Mobile keyboards: the wrong type here means a player fights autocapitalisation on their address.
	_email.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_EMAIL_ADDRESS
	_email.custom_minimum_size = Vector2(0, 44)   # 44pt: the smallest reliably tappable target
	# Tapping a field you have already filled almost always means "this is wrong, replace it" — on a
	# phone, positioning a caret to edit in place is far more work than retyping.
	_email.select_all_on_focus = true
	_email.clear_button_enabled = true
	box.add_child(_field_row(_email))

	_password = LineEdit.new()
	_password.placeholder_text = "password"
	_password.secret = true
	_password.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_PASSWORD
	_password.custom_minimum_size = Vector2(0, 44)
	_password.select_all_on_focus = true
	# A masked field on a phone keyboard is the easiest thing in the world to fumble, and the only
	# feedback is a failed sign-in that blames your credentials.
	var reveal := Button.new()
	reveal.toggle_mode = true
	reveal.custom_minimum_size = Vector2(48, 44)
	var eye := EyeIcon.new()
	eye.set_anchors_preset(Control.PRESET_FULL_RECT)
	eye.mouse_filter = Control.MOUSE_FILTER_IGNORE   # the Button owns the tap; the icon is decoration
	reveal.add_child(eye)
	reveal.toggled.connect(func(on: bool) -> void:
		_password.secret = not on
		eye.closed = not on
		eye.queue_redraw())
	box.add_child(_field_row(_password, reveal))

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.modulate = Color(1, 0.55, 0.5)
	box.add_child(_status)

	_primary = Button.new()
	_primary.text = "Sign in"
	_primary.custom_minimum_size = Vector2(0, 48)
	_primary.pressed.connect(_submit)
	box.add_child(_primary)

	_toggle = Button.new()
	_toggle.text = "No account? Create one"
	_toggle.flat = true
	_toggle.pressed.connect(_flip_mode)
	box.add_child(_toggle)

	var forgot := Button.new()
	forgot.text = "Forgot password"
	forgot.flat = true
	forgot.modulate = Color(1, 1, 1, 0.5)
	forgot.pressed.connect(_recover)
	box.add_child(forgot)

	# Enter submits from either field — on desktop and on a phone's on-screen keyboard.
	_email.text_submitted.connect(func(_t): _submit())
	_password.text_submitted.connect(func(_t): _submit())


## A LineEdit, and whatever belongs beside it. No Paste button: pasting is the PLATFORM's gesture —
## hold the field — and `_on_field_input` below is what makes that gesture exist here at all.
func _field_row(le: LineEdit, extra: Control = null) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.gui_input.connect(_on_field_input.bind(le))
	row.add_child(le)
	if extra != null:
		row.add_child(extra)
	return row


## HOLD TO PASTE — the gesture everyone already knows, which Godot does not give you for free.
##
## `input_devices/pointing/emulate_mouse_from_touch` is TRUE by default, so a finger arrives as a
## LEFT click. LineEdit opens its Cut/Copy/Paste menu on a RIGHT click, and there is no touch path to
## it — so on a phone the menu is unreachable and a long press does nothing at all. That absence is
## why this screen used to carry an explicit Paste button.
##
## A drag cancels the hold: dragging inside a field is a text SELECTION, and stealing it for a menu
## would break selecting to replace what you typed.
func _on_field_input(ev: InputEvent, le: LineEdit) -> void:
	if ev is InputEventMouseButton:
		var mb: InputEventMouseButton = ev
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_hold_le = le if mb.pressed else null
			_hold_at = Time.get_ticks_msec() / 1000.0
			_hold_from = mb.global_position
	elif ev is InputEventMouseMotion and _hold_le != null:
		if (ev as InputEventMouseMotion).global_position.distance_to(_hold_from) > HOLD_SLOP_PX:
			_hold_le = null


func _process(_dt: float) -> void:
	if _hold_le == null or not visible:
		return
	if (Time.get_ticks_msec() / 1000.0) - _hold_at < HOLD_S:
		return
	var le := _hold_le
	_hold_le = null
	if not is_instance_valid(le):
		return
	var menu: PopupMenu = le.get_menu()
	if menu == null:
		return
	le.grab_focus()
	# Screen coordinates, not viewport ones — a Popup is its own window. Anchored just under the
	# field rather than at the finger, so it is never born beneath the thumb that summoned it.
	var at := le.get_screen_position() + Vector2(0.0, le.size.y + 4.0)
	menu.reset_size()
	menu.popup(Rect2i(Vector2i(at), Vector2i.ZERO))


## Put the keyboard away. Tapping off a field is how every other app on the phone does this, and
## without it the keyboard sits over the Sign in button — which reads as the button not working.
func _dismiss_keyboard() -> void:
	var f := get_viewport().gui_get_focus_owner()
	if f != null:
		f.release_focus()
	DisplayServer.virtual_keyboard_hide()


func _flip_mode() -> void:
	_mode_signup = not _mode_signup
	_primary.text = "Create account" if _mode_signup else "Sign in"
	_toggle.text = "Have an account? Sign in" if _mode_signup else "No account? Create one"
	_status.text = ""


func _submit() -> void:
	if _busy:
		return
	var em := _email.text.strip_edges()
	var pw := _password.text
	# Trailing CR/LF ONLY. That is a paste artefact — no keyboard produces one inside a password — and
	# it fails sign-in while the field looks perfectly correct. Spaces are deliberately left alone,
	# since they can legitimately be part of a password and silently eating them would be worse.
	while pw.ends_with("\n") or pw.ends_with("\r"):
		pw = pw.substr(0, pw.length() - 1)
	# Checked here so an obvious mistake costs no round trip, and the message names the actual
	# problem instead of relaying a server error the player cannot act on.
	if em.find("@") < 0:
		_status.text = "Enter a valid email address."
		return
	if pw.length() < 6:
		_status.text = "Password must be at least 6 characters."
		return

	_busy = true
	_primary.disabled = true
	_status.modulate = Color(1, 1, 1, 0.6)
	_status.text = "Creating account…" if _mode_signup else "Signing in…"

	# Spelled out rather than a ternary: both branches are coroutines, and GDScript requires `await`
	# on each CALL, not on the expression's result.
	var res: Dictionary
	if _mode_signup:
		res = await Auth.sign_up(em, pw)
	else:
		res = await Auth.sign_in(em, pw)
	_busy = false
	_primary.disabled = false

	if bool(res.get("ok", false)):
		passed.emit()
		return
	# An existing address on the signup path is the single most common failure — say what to do
	# about it rather than echoing "User already registered".
	var err := str(res.get("error", "Could not sign in."))
	if _mode_signup and err.to_lower().find("already") >= 0:
		_status.text = "That email already has an account — switch to Sign in."
	else:
		_status.text = err
	_status.modulate = Color(1, 0.55, 0.5)


func _recover() -> void:
	var em := _email.text.strip_edges()
	if em.find("@") < 0:
		_status.text = "Enter your email above first."
		return
	await Auth.recover(em)
	_status.modulate = Color(1, 1, 1, 0.6)
	# Deliberately unconditional: confirming whether an address exists would leak account existence.
	_status.text = "If that address has an account, a reset link is on its way."


func _on_failed(_reason: String) -> void:
	pass   # surfaced inline by _submit; the signal exists for games/telemetry that want it
