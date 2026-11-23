# Docs

- [setup.md](setup.md): requirements, signing with a free Apple ID, permissions, Info.plist keys.
- [internals.md](internals.md): discovery, capture and encode, transport, input, pairing, latency tuning.

## Media

Nothing is committed yet. The README has a commented-out slot for `docs/demo.gif` under the tagline.

TODO: capture it. It needs a real Mac and iPad, so it has to be done by hand.

1. Run MacHost and PadClient and connect. Turn on the debug overlay (the waveform button) so the
   capture-to-display latency is visible.
2. Film the iPad and the Mac in one shot for about 10 seconds: drag a window on the Mac, then draw with
   the Pencil on the iPad. A phone video shows the latency honestly; a screen recording cannot.
3. Convert to a GIF 800 px wide or less and under 8 MB, save it as `docs/demo.gif`, and uncomment the
   image line near the top of the README.
4. Optional: `docs/overlay.png`, a screenshot of the overlay on a real iPad over Wi-Fi. That number can
   then go in the Results table next to the simulator measurement.
