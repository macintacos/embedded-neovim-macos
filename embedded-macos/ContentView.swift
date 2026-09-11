//
//  ContentView.swift
//  embedded-macos
//
//  Created by Julian Torres on 9/11/26.
//

import SwiftUI

struct ContentView: View {
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Type something…", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.title3)
            .focused($focused)
            .padding(.horizontal, 20)
            .padding(.top, 36) // clears the traffic lights under the hidden title bar
            .frame(minWidth: 480, maxWidth: .infinity, minHeight: 240, maxHeight: .infinity, alignment: .topLeading)
            .onAppear { focused = true }
    }
}

#Preview {
    ContentView()
}
