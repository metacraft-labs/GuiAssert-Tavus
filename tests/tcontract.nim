## The plugin against DemoVideoStudio's provider contract, through the
## contract's own conformance kit: its name, its registration, its
## availability probe, and — without credentials or a local model — its
## refusal by name. Offline: nothing here calls the provider's service.

import std/unittest
import demo_video_studio/plugins/kit
import gui_assert_tavus

suite "gui_assert_tavus against the provider contract":
  test "the provider conforms":
    let problems = talkingHeadProblems(tavusProvider())
    checkpoint $problems
    check problems.len == 0
