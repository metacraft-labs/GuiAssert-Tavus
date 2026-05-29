## Pure tests for Tavus emotive translation + capability self-description.

import std/[json, options, unittest]
import gui_assert/talking_head, gui_assert/emotive
import gui_assert_tavus

suite "Tavus emotiveToProviderSettings":

  test "background mode is forwarded onto providerSettings":
    var c = initEmotive()
    c.background = some(bmGreenScreen)
    let j = emotiveToProviderSettings(c)
    check j["background"].getStr == "green_screen"

  test "voice + emotion fields are dropped since backend ignores them":
    var c = initEmotive()
    c.voiceSpeed = some(1.2)
    c.emotion = some(eHappy)
    let j = emotiveToProviderSettings(c)
    check not j.hasKey("voice_speed")
    check not j.hasKey("emotion")

  test "caller-set base values win":
    var c = initEmotive()
    c.background = some(bmGreenScreen)
    let base = %*{"background": "trained"}
    let j = emotiveToProviderSettings(c, base)
    check j["background"].getStr == "trained"

suite "Tavus capabilities":

  test "self-describes as text-only with replica-baked styling":
    check TavusCapabilities.supportsTextInput
    check not TavusCapabilities.supportsAudioInput
    check not TavusCapabilities.supportsEmotion
    check not TavusCapabilities.supportsGreenScreen
    check not TavusCapabilities.supportsVoiceTuning
