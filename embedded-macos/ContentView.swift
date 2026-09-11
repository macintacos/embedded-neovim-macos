//
//  ContentView.swift
//  embedded-macos
//
//  Created by Julian Torres on 9/11/26.
//

import SwiftUI

struct ContentView: View {
    let neovimEnabled: Bool
    @State private var status = ""

    var body: some View {
        NeovimTextField(neovimEnabled: neovimEnabled, status: $status)
            .padding(.horizontal, 20)
            .padding(.top, 36) // clears the traffic lights under the hidden title bar
            .frame(minWidth: 480, minHeight: 240)
            .overlay(alignment: .bottomTrailing) {
                if neovimEnabled {
                    Text(status)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
            }
    }
}

#Preview {
    ContentView(neovimEnabled: true)
}
