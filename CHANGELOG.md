# DoesItDie

## Unreleased

- **Threat Plates:** the nameplate marker now really shows on its health bar (v0.8.2's fix looked in the wrong place). Thanks to adamkm123 and WEEDWIZARD420__.

## v0.8.3

**Restart the game fully after updating** (not just /reload): this version adds new files.

- **Portuguese (Brazil) and Chinese (Traditional and Simplified) clients:** your DoTs are read there too. If one isn't picked up, a `/did debug` log helps (issues #19 and #20 on GitHub).

## v0.8.2

**Restart the game fully after updating** (not just /reload): this version adds a new file.

- **Plater:** the nameplate kill icon is back (it went missing in v0.7.0 with some nameplate addons), and Plater's health bar is found more reliably. Thanks to tuwzz for the report.
- **Threat Plates:** the nameplate marker finds its health bar too.
- **Korean client:** your DoTs are read on Korean (koKR) clients. If one isn't picked up, a `/did debug` log helps (issue #18 on GitHub).
- **German options window:** set Advanced > Window language to Deutsch (or Auto on a German client), then /reload. Thanks to thecodingcortex.
- **French client fixes:** Immolation and Plaie d'agonie are read again. Thanks to gou-gouze.
- **Tracking fixes** (thanks to Ironship):
  - Two DoTs of the same school ticking at the same moment are both counted (one was dropped before).
  - A DoT whose ticks a shield absorbs is no longer dropped.
  - A melee hit landing just before a bleed's tick is no longer learned as the bleed's size.
  - Combo points built on one mob are no longer used for a finisher on the next.
  - DoTs cast on your soft or mouseover target go on that mob, and never on a friendly target.

## v0.8.1

- **Plater and other nameplate addons:** the nameplate marker finds their health bars automatically. If yours still doesn't show it, Advanced > Nameplate health bar takes the path to its bar.

## v0.8.0

**Restart the game fully after updating** (not just /reload): this version adds new files.

- **Focus frame:** the marker and kill icon also show on your focus's health bar (Blizzard's, EllesmereUI's, or a custom one under Advanced), with its own tab (Focus) for its look and a focus frame in the options preview. `/cast [@focus]` macros put the DoT on your focus. Thanks to toughnuts99 for the patch.
- **Dungeons:** where mobs can't be told apart by ID, DoTs are tracked per mob through its nameplate, so tab-dotting a pack works (needs enemy nameplates on). Thanks to Staypuft.
- **Window language** setting (Advanced): the options window can now be translated. No translations yet; see issue #10 on GitHub if you'd like to help.
- The options window is a little wider, so all tabs fit.

## v0.7.1

- **Immolation Trap** is tracked. The DoT starts on whichever mob springs the trap.

## v0.7.0

**Other UIs**

- **EllesmereUI:** the marker sits on EllesmereUI's nameplates and target frame health bars, and the kill icon on
  its portrait.
- **Platynator:** the nameplate marker and kill icon anchor to Platynator's plates.
- Nameplate addons that hide Blizzard's bar no longer get a stray box above the plate.

**Languages:** German, Spanish and French clients read your DoTs. If something isn't picked up on your client, a
`/did debug` log helps a lot.

**New**

- **Estimate while casting:** DoTs with a cast time (Immolate) show as soon as you start casting, and disappear if
  the cast is interrupted. Can be turned off under Advanced.
- **Learned tick sizes viewer** (Advanced > View, or `/did ticks`): what each of your DoTs really ticks for next to
  its tooltip, with spell icons and tooltips. Shift-click a spell to link it.
- Kill icon size up to 128, on the target frame and on nameplates.
- New default nameplate look: school colors, stripes and a dashed gold outline. Saved settings are kept.
- An icon in the AddOns list.

**Fixes**

- A bleed on a mob immune to it no longer shows on the health bar.
- The kill icon and marker no longer stay on a dead mob's nameplate.

Thanks to Merryfett, cdhawke, Ironship, 13Karl, gou-gouze, toughnuts99 and Zephancode on GitHub.
