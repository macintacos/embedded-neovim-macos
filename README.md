# embedded-neovim-macos

A proof of concept that embeds [Neovim](https://neovim.io) in a native macOS text field. With it enabled, every keystroke goes to a headless `nvim --embed` process, and the field renders the resulting text, cursor, and selection — so you get real Neovim editing in what still looks like a stock macOS text input.

## Try it

1. Install Neovim (`brew install neovim`).
2. Open `embedded-macos.xcodeproj` in Xcode and run the app.
3. Press ⌘, and check **Enable embedded Neovim**.
