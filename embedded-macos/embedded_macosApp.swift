//
//  embedded_macosApp.swift
//  embedded-macos
//
//  Created by Julian Torres on 9/11/26.
//

import SwiftUI

@main
struct embedded_macosApp: App {
    @AppStorage("neovimEnabled") private var neovimEnabled = false

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)

        Settings {
            Toggle("Enable embedded Neovim", isOn: $neovimEnabled)
                .padding(20)
        }
    }
}
