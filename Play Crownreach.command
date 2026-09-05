#!/bin/zsh
# Explore the rebuilt city in a fresh session without overwriting a career.
exec /usr/bin/open -n -a /Applications/Godot.app --args --path "${0:A:h}" -- citypreview
