MAGGINEPHEW stream overlays (OBS)
=================================
Add each one in OBS:  Sources > + > Browser > tick "Local file" > pick the .html file.

  starting.html   1920 x 1080   "Starting soon" + 5-minute countdown
  brb.html        1920 x 1080   "Be right back" + how long you've been away
  ending.html     1920 x 1080   "Thanks for watching"
  camera.html     webcam width x (webcam height + 40)   frame around your camera with the logo on it
                  e.g. camera 480x270 -> browser source 480x310, same position as the camera
  badge.html      440 x 130     small logo for a corner while live
  chat.html       460 x 780     Twitch chat (Just Chatting)
  chatting.html   1920 x 1080   Just Chatting background
  stats.html      760 x 70      live viewers, follower count + latest follower (run stream-stats-setup once first)
  alert.html      1100 x 640    follower alert (any size works, it scales) (top of the Live scene; tick 'Control audio via OBS')
                  no sound: ?sound=0    own sound: ?sound=yourfile.mp3

Tips
  * Tick "Refresh browser when scene becomes active" on starting/brb so the timers restart.
  * Different countdown: untick "Local file" and use a URL instead, e.g.
        file:///home/unome/Videos/stream-overlays/starting.html?min=10
        file:///home/unome/Videos/stream-overlays/starting.html?at=20:30
  * Change the text in the frame gap:  ?label=YOUR TEXT   (works on every page)

Testing (OBS open):  run  stream-test  in a terminal
  stream-test follow [name]   follower alert + counter bar
  stream-test burst           three follows in a row
  stream-test stats           sample numbers on the counter bar for 15 s

Keyboard (Hyprland, works in games):  Super+Ctrl+1 Starting Soon  2 Live  3 BRB  4 Ending  5 Just Chatting
                                      Super+Ctrl+M mute mic on stream   Super+Ctrl+Up/Down music volume
Music on its own slider:  stream-music on   (before going live; switches back when OBS closes)
Nightbot commands: nightbot-commands.txt
