## Which language the interface speaks: English or German.
##
## Only those two. ETR shipped thirteen translations and all thirteen are still
## imported and registered, but they cover ETR's 111 strings and nothing this
## rebuild added — the network lobby, ghosts, opponents, the settings screen.
## A French locale would have been handed a menu half in French and half in
## English, so the locale is pinned to one of the two languages every string is
## written in (`i18n/ui.csv` beside the imported `penguinracer.csv`), and the
## other eleven are simply never selected.
##
## "auto" follows the platform: [method OS.get_locale] is the desktop's `LANG`
## or Windows' display language, Android's system language, and in a browser
## `navigator.language`. German there means German; anything else means English.
## The settings screen, `[game] language` and `--lang=`/`?lang=` override it.
##
## Static and pure apart from [method apply], so [TestConfig] can drive the
## decision without touching the [TranslationServer].
class_name Language
extends RefCounted

## Follow the platform. What `penguinracer.cfg` holds when nobody has chosen.
const AUTO := "auto"
## The languages every interface string exists in, in the settings screen's
## order. The first is the fallback for a platform speaking anything else.
const CODES: PackedStringArray = ["en", "de"]
## Each language named in itself, which is how a language picker has to read:
## somebody stuck in a menu they cannot read is looking for their own word.
const NATIVE_NAMES: PackedStringArray = ["English", "Deutsch"]

## `"de"`, `"DE"`, `"de_DE"` or `"de-AT"` → `"de"`; `"auto"` → [constant AUTO].
## Anything else — a language this build does not speak, a typo in the file —
## is [param fallback].
static func parse(text: String, fallback: String = AUTO) -> String:
	var trimmed: String = text.strip_edges().to_lower()
	if trimmed == AUTO:
		return AUTO
	var code: String = _language_of(trimmed)
	return code if CODES.has(code) else fallback

## The language to use on a platform whose locale is [param os_locale].
static func detect(os_locale: String) -> String:
	var code: String = _language_of(os_locale.strip_edges().to_lower())
	return code if CODES.has(code) else CODES[0]

## What [param setting] comes to on a platform whose locale is [param os_locale]:
## the language it names, or the platform's when it names none.
static func resolve(setting: String, os_locale: String) -> String:
	var chosen: String = parse(setting)
	return chosen if chosen != AUTO else detect(os_locale)

## The name to show for [param code] — in that language, not the current one.
static func native_name(code: String) -> String:
	var index: int = CODES.find(code)
	return NATIVE_NAMES[index] if index >= 0 else code

## Switch the interface to what [param setting] resolves to here. Text already on
## screen that was put there with `tr()` keeps the old language until its screen
## is rebuilt — see [method SettingsMenu._accept].
static func apply(setting: String) -> void:
	TranslationServer.set_locale(resolve(setting, OS.get_locale()))

## `de_DE`, `de-DE` and `de` all speak `de`.
static func _language_of(locale: String) -> String:
	return locale.get_slice("_", 0).get_slice("-", 0)
