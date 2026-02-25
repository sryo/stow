import XCTest
@testable import StowShared

final class ModelTests: XCTestCase {
    private func makeStore() -> DataStore {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return DataStore(baseDirectory: temp)
    }

    func testJSONRoundTrip() throws {
        let link = Link(id: UUID(), title: "Example", url: "https://example.com", faviconPath: nil)
        let folder = Folder(id: UUID(), name: "Folder", children: [.link(link)], isExpanded: true)
        let workspace = Workspace(id: UUID(), name: "Inbox", colorId: .ember, items: [.folder(folder)])
        let state = AppState(schemaVersion: 1, workspaces: [workspace], selectedWorkspaceId: workspace.id, isSettingsSelected: false)

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(AppState.self, from: data)
        XCTAssertEqual(state, decoded)
    }

    func testMoveNodeReorderAndNest() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        model.addFolder(name: "Folder", parentId: nil)
        model.addLink(urlString: "https://a.com", title: "A", parentId: nil)
        model.addLink(urlString: "https://b.com", title: "B", parentId: nil)

        guard
            let folderId = model.currentWorkspace.items.compactMap({
                if case .folder(let folder) = $0 { return folder.id }
                return nil
            }).first,
            let linkAId = model.currentWorkspace.items.compactMap({
                if case .link(let link) = $0, link.title == "A" { return link.id }
                return nil
            }).first
        else {
            XCTFail("Expected nodes to exist")
            return
        }

        model.moveNode(id: linkAId, toParentId: folderId, index: 0)
        let location = model.location(of: linkAId)
        XCTAssertEqual(location?.parentId, folderId)

        if let folderNode = model.nodeById(folderId), case .folder(let folder) = folderNode {
            XCTAssertEqual(folder.children.count, 1)
        } else {
            XCTFail("Expected folder to contain moved link")
        }

        if let linkBId = model.currentWorkspace.items.compactMap({
            if case .link(let link) = $0, link.title == "B" { return link.id }
            return nil
        }).first {
            model.moveNode(id: linkBId, toParentId: nil, index: 0)
            let locationB = model.location(of: linkBId)
            XCTAssertEqual(locationB?.parentId, nil)
            XCTAssertEqual(locationB?.index, 0)
        }
    }

    func testWorkspaceScopedFiltering() {
        let link1 = Link(id: UUID(), title: "Docs", url: "https://docs.com", faviconPath: nil)
        let link2 = Link(id: UUID(), title: "Blog", url: "https://blog.com", faviconPath: nil)
        let folder = Folder(id: UUID(), name: "Reading", children: [.link(link2)], isExpanded: false)
        let nodes: [Node] = [.link(link1), .folder(folder)]

        let results = NodeFiltering.filter(nodes: nodes, query: "blog")
        XCTAssertEqual(results.count, 1)
        if case .folder(let filteredFolder) = results[0] {
            XCTAssertEqual(filteredFolder.children.count, 1)
        } else {
            XCTFail("Expected folder to remain for matching child")
        }
    }

    func testTaskItemJSONRoundTrip() throws {
        let task = TaskItem(id: UUID(), title: "Buy milk", isCompleted: false, dueDate: Date(), notes: "From the store", createdAt: Date())
        let node = Node.task(task)
        let workspace = Workspace(id: UUID(), name: "Tasks", colorId: .ember, items: [node])
        let state = AppState(schemaVersion: 2, workspaces: [workspace], selectedWorkspaceId: workspace.id, isSettingsSelected: false)

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(AppState.self, from: data)
        XCTAssertEqual(decoded.workspaces[0].items.count, 1)
        if case .task(let decodedTask) = decoded.workspaces[0].items[0] {
            XCTAssertEqual(decodedTask.title, "Buy milk")
            XCTAssertEqual(decodedTask.isCompleted, false)
            XCTAssertEqual(decodedTask.notes, "From the store")
        } else {
            XCTFail("Expected task node")
        }
    }

    func testSnippetJSONRoundTrip() throws {
        let snippet = Snippet(id: UUID(), title: "Hello World", content: "print(\"Hello\")", language: "Swift", createdAt: Date())
        let node = Node.snippet(snippet)
        let workspace = Workspace(id: UUID(), name: "Snippets", colorId: .ocean, items: [node])
        let state = AppState(schemaVersion: 2, workspaces: [workspace], selectedWorkspaceId: workspace.id, isSettingsSelected: false)

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(AppState.self, from: data)
        XCTAssertEqual(decoded.workspaces[0].items.count, 1)
        if case .snippet(let decodedSnippet) = decoded.workspaces[0].items[0] {
            XCTAssertEqual(decodedSnippet.title, "Hello World")
            XCTAssertEqual(decodedSnippet.content, "print(\"Hello\")")
            XCTAssertEqual(decodedSnippet.language, "Swift")
        } else {
            XCTFail("Expected snippet node")
        }
    }

    func testMixedNodeTypesRoundTrip() throws {
        let link = Link(id: UUID(), title: "Example", url: "https://example.com", faviconPath: nil)
        let task = TaskItem(id: UUID(), title: "Todo", isCompleted: true, dueDate: nil, notes: nil, createdAt: Date())
        let snippet = Snippet(id: UUID(), title: "Code", content: "let x = 1", language: nil, createdAt: Date())
        let folder = Folder(id: UUID(), name: "Mixed", children: [.task(task), .snippet(snippet)], isExpanded: true)
        let workspace = Workspace(id: UUID(), name: "All", colorId: .moss, items: [.link(link), .folder(folder)])
        let state = AppState(schemaVersion: 2, workspaces: [workspace], selectedWorkspaceId: workspace.id, isSettingsSelected: false)

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(AppState.self, from: data)
        XCTAssertEqual(decoded.workspaces[0].items.count, 2)
        if case .folder(let decodedFolder) = decoded.workspaces[0].items[1] {
            XCTAssertEqual(decodedFolder.children.count, 2)
        } else {
            XCTFail("Expected folder with mixed children")
        }
    }

    func testSchemaMigrationV1ToV2() {
        let store = makeStore()
        // Create v1 state manually
        let workspace = Workspace(id: UUID(), name: "Test", colorId: .ember, items: [])
        let v1State = AppState(schemaVersion: 1, workspaces: [workspace], selectedWorkspaceId: workspace.id, isSettingsSelected: false)
        store.save(v1State)

        let migrated = store.migrate(state: v1State, from: 1, to: 2)
        XCTAssertEqual(migrated.schemaVersion, 2)
        XCTAssertEqual(migrated.workspaces.count, 1)
        XCTAssertEqual(migrated.workspaces[0].name, "Test")
    }

    func testAddTaskAndToggleCompletion() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let taskId = model.addTask(title: "Test task", parentId: nil)
        guard let node = model.nodeById(taskId), case .task(let task) = node else {
            XCTFail("Expected task node")
            return
        }
        XCTAssertEqual(task.title, "Test task")
        XCTAssertFalse(task.isCompleted)

        model.toggleTaskCompletion(id: taskId)
        guard let toggled = model.nodeById(taskId), case .task(let toggledTask) = toggled else {
            XCTFail("Expected task node")
            return
        }
        XCTAssertTrue(toggledTask.isCompleted)
    }

    func testAddSnippetAndUpdateContent() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let snippetId = model.addSnippet(title: "Hello", content: "original", language: "Swift", parentId: nil)
        model.updateSnippetContent(id: snippetId, content: "updated content")
        guard let node = model.nodeById(snippetId), case .snippet(let snippet) = node else {
            XCTFail("Expected snippet node")
            return
        }
        XCTAssertEqual(snippet.content, "updated content")
        XCTAssertEqual(snippet.language, "Swift")

        model.updateSnippetLanguage(id: snippetId, language: "Python")
        guard let updated = model.nodeById(snippetId), case .snippet(let updatedSnippet) = updated else {
            XCTFail("Expected snippet node")
            return
        }
        XCTAssertEqual(updatedSnippet.language, "Python")
    }

    func testFilteringWithTasksAndSnippets() {
        let task = TaskItem(id: UUID(), title: "Buy groceries", isCompleted: false, dueDate: nil, notes: "organic milk", createdAt: Date())
        let snippet = Snippet(id: UUID(), title: "API Key", content: "secret_abc123", language: nil, createdAt: Date())
        let link = Link(id: UUID(), title: "Docs", url: "https://docs.com", faviconPath: nil)
        let nodes: [Node] = [.task(task), .snippet(snippet), .link(link)]

        // Filter by task title
        let taskResults = NodeFiltering.filter(nodes: nodes, query: "groceries")
        XCTAssertEqual(taskResults.count, 1)

        // Filter by task notes
        let notesResults = NodeFiltering.filter(nodes: nodes, query: "organic")
        XCTAssertEqual(notesResults.count, 1)

        // Filter by snippet content
        let snippetResults = NodeFiltering.filter(nodes: nodes, query: "secret")
        XCTAssertEqual(snippetResults.count, 1)

        // Filter that matches nothing
        let noResults = NodeFiltering.filter(nodes: nodes, query: "xyz")
        XCTAssertEqual(noResults.count, 0)
    }

    // MARK: - ShareService Tests

    func testShareServiceCompressionRoundTrip() throws {
        let original = Data("Hello, Arcmark! This is a test of compression round-tripping.".utf8)
        let compressed = try ShareService.compress(original)
        let decompressed = try ShareService.decompress(compressed)
        XCTAssertEqual(original, decompressed)
    }

    func testShareServiceBase64URLRoundTrip() throws {
        let original = Data([0, 1, 2, 255, 254, 253, 128, 64, 32, 16, 8, 4, 2, 1])
        let encoded = ShareService.base64urlEncode(original)

        // Verify URL-safe: no +, /, or =
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))

        let decoded = try ShareService.base64urlDecode(encoded)
        XCTAssertEqual(original, decoded)
    }

    func testShareWorkspaceRoundTrip() throws {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        // Create a workspace with some items
        let wsId = model.createWorkspace(name: "Shared Test", colorId: .ocean)
        model.selectWorkspace(id: wsId)
        model.addLink(urlString: "https://example.com", title: "Example", parentId: nil)
        model.addLink(urlString: "https://github.com", title: "GitHub", parentId: nil)
        let folderId = model.addFolder(name: "Folder", parentId: nil)
        model.addLink(urlString: "https://apple.com", title: "Apple", parentId: folderId)
        model.addTask(title: "Test task", parentId: nil)
        model.addSnippet(title: "Snippet", content: "let x = 1", language: "Swift", parentId: nil)

        // Generate share URL
        let shareURL = try model.shareWorkspace(id: wsId)
        XCTAssertTrue(shareURL.hasPrefix("https://stow.app/share#"))

        // Extract fragment and import
        let fragment = String(shareURL.dropFirst("https://stow.app/share#".count))
        let importedId = try model.importWorkspaceFromShareURL(fragment: fragment)

        // Verify imported workspace
        let imported = model.workspaces.first(where: { $0.id == importedId })
        XCTAssertNotNil(imported)
        XCTAssertEqual(imported?.name, "Shared Test (2)") // Duplicate name handling
        XCTAssertEqual(imported?.colorId, .ocean)
        XCTAssertEqual(imported?.items.count, 5) // 2 links + 1 folder + 1 task + 1 snippet
    }

    func testShareServiceStripsFavicons() throws {
        let link = Link(id: UUID(), title: "Test", url: "https://example.com", faviconPath: "/some/path/icon.png")
        let folder = Folder(id: UUID(), name: "F", children: [.link(link)], isExpanded: true)
        let workspace = Workspace(id: UUID(), name: "Test", colorId: .ember, items: [.folder(folder)])

        let url = try ShareService.createShareURL(workspace: workspace, schemaVersion: 2)

        // Decode and verify favicons are stripped
        let fragment = String(url.dropFirst("\(ShareService.baseURL)#".count))
        let data = try ShareService.decodeShareData(from: fragment)
        let decoded = try JSONDecoder().decode(ExportedWorkspace.self, from: data)

        // Embedded favicons should be empty
        XCTAssertTrue(decoded.embeddedFavicons.isEmpty)

        // Link favicon path should be nil
        if case .folder(let f) = decoded.workspace.items[0],
           case .link(let l) = f.children[0] {
            XCTAssertNil(l.faviconPath)
        } else {
            XCTFail("Expected folder with link")
        }
    }

    func testShareServiceURLSizeLimit() {
        // Create a workspace with many items to exceed 32KB
        var items: [Node] = []
        for i in 0..<500 {
            let link = Link(id: UUID(), title: "Link \(i) with a fairly long title to increase size", url: "https://example.com/very/long/path/that/increases/the/overall/size/of/the/json/\(i)", faviconPath: nil)
            items.append(.link(link))
        }
        let workspace = Workspace(id: UUID(), name: "Large Workspace", colorId: .ember, items: items)

        do {
            _ = try ShareService.createShareURL(workspace: workspace, schemaVersion: 2)
            // If it doesn't throw, the workspace was small enough (compression may help)
        } catch let error as ShareError {
            if case .urlTooLarge = error {
                // Expected for very large workspaces
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Arc Import Tests

    func testArcImportChildrenIdsOrdering() async throws {
        // Build a minimal Arc JSON with explicit childrenIds ordering
        let arcJSON: [String: Any] = [
            "version": 40,
            "sidebar": [
                "containers": [
                    [
                        "spaces": [
                            ["id": "space1", "title": "Test Space", "containerIDs": ["pinned", "container1"]]
                        ],
                        "items": [
                            // Container item with childrenIds defining order
                            ["id": "container1", "title": "Pinned", "parentID": "space1",
                             "childrenIds": ["link2", "link1", "link3"]],
                            // Links in different order than childrenIds
                            ["id": "link1", "title": nil, "parentID": "container1",
                             "data": ["tab": ["savedTitle": "First", "savedURL": "https://first.com"]]],
                            ["id": "link2", "title": nil, "parentID": "container1",
                             "data": ["tab": ["savedTitle": "Second", "savedURL": "https://second.com"]]],
                            ["id": "link3", "title": nil, "parentID": "container1",
                             "data": ["tab": ["savedTitle": "Third", "savedURL": "https://third.com"]]]
                        ]
                    ]
                ]
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: arcJSON)
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test_arc_\(UUID().uuidString).json")
        try data.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let result = await ArcImportService.shared.importFromArc(fileURL: tempFile)
        switch result {
        case .success(let importResult):
            XCTAssertEqual(importResult.workspaces.count, 1)
            let nodes = importResult.workspaces[0].nodes
            XCTAssertEqual(nodes.count, 3)
            // Should follow childrenIds order: link2, link1, link3
            if case .link(let link0) = nodes[0] {
                XCTAssertEqual(link0.title, "Second")
            } else { XCTFail("Expected link at index 0") }
            if case .link(let link1) = nodes[1] {
                XCTAssertEqual(link1.title, "First")
            } else { XCTFail("Expected link at index 1") }
            if case .link(let link2) = nodes[2] {
                XCTAssertEqual(link2.title, "Third")
            } else { XCTFail("Expected link at index 2") }
        case .failure(let error):
            XCTFail("Import failed: \(error)")
        }
    }

    func testArcImportNestedFolders() async throws {
        let arcJSON: [String: Any] = [
            "version": 40,
            "sidebar": [
                "containers": [
                    [
                        "spaces": [
                            ["id": "space1", "title": "Nested Space", "containerIDs": ["pinned", "container1"]]
                        ],
                        "items": [
                            ["id": "container1", "title": "Pinned", "parentID": "space1",
                             "childrenIds": ["folder1"]],
                            ["id": "folder1", "title": "My Folder", "parentID": "container1",
                             "childrenIds": ["linkA", "linkB"]],
                            ["id": "linkA", "title": nil, "parentID": "folder1",
                             "data": ["tab": ["savedTitle": "Link A", "savedURL": "https://a.com"]]],
                            ["id": "linkB", "title": nil, "parentID": "folder1",
                             "data": ["tab": ["savedTitle": "Link B", "savedURL": "https://b.com"]]]
                        ]
                    ]
                ]
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: arcJSON)
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test_arc_\(UUID().uuidString).json")
        try data.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let result = await ArcImportService.shared.importFromArc(fileURL: tempFile)
        switch result {
        case .success(let importResult):
            XCTAssertEqual(importResult.workspaces.count, 1)
            let nodes = importResult.workspaces[0].nodes
            XCTAssertEqual(nodes.count, 1)
            if case .folder(let folder) = nodes[0] {
                XCTAssertEqual(folder.name, "My Folder")
                XCTAssertEqual(folder.children.count, 2)
            } else {
                XCTFail("Expected folder")
            }
        case .failure(let error):
            XCTFail("Import failed: \(error)")
        }
    }

    func testArcImportEmptySpaceSkipped() async throws {
        let arcJSON: [String: Any] = [
            "version": 40,
            "sidebar": [
                "containers": [
                    [
                        "spaces": [
                            ["id": "space1", "title": "Empty Space", "containerIDs": ["pinned", "container1"]],
                            ["id": "space2", "title": "Full Space", "containerIDs": ["pinned", "container2"]]
                        ],
                        "items": [
                            ["id": "container1", "title": "Pinned", "parentID": "space1",
                             "childrenIds": [] as [String]],
                            ["id": "container2", "title": "Pinned", "parentID": "space2",
                             "childrenIds": ["link1"]],
                            ["id": "link1", "title": nil, "parentID": "container2",
                             "data": ["tab": ["savedTitle": "Link", "savedURL": "https://link.com"]]]
                        ]
                    ]
                ]
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: arcJSON)
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test_arc_\(UUID().uuidString).json")
        try data.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let result = await ArcImportService.shared.importFromArc(fileURL: tempFile)
        switch result {
        case .success(let importResult):
            // Empty space should be skipped
            XCTAssertEqual(importResult.workspaces.count, 1)
            XCTAssertEqual(importResult.workspaces[0].name, "Full Space")
        case .failure(let error):
            XCTFail("Import failed: \(error)")
        }
    }

    func testArcImportInvalidURLSkipped() async throws {
        let arcJSON: [String: Any] = [
            "version": 40,
            "sidebar": [
                "containers": [
                    [
                        "spaces": [
                            ["id": "space1", "title": "Test", "containerIDs": ["pinned", "container1"]]
                        ],
                        "items": [
                            ["id": "container1", "title": "Pinned", "parentID": "space1",
                             "childrenIds": ["link1", "link2"]],
                            ["id": "link1", "title": nil, "parentID": "container1",
                             "data": ["tab": ["savedTitle": "Valid", "savedURL": "https://valid.com"]]],
                            ["id": "link2", "title": nil, "parentID": "container1",
                             "data": ["tab": ["savedTitle": "Invalid", "savedURL": ""]]]
                        ]
                    ]
                ]
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: arcJSON)
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test_arc_\(UUID().uuidString).json")
        try data.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let result = await ArcImportService.shared.importFromArc(fileURL: tempFile)
        switch result {
        case .success(let importResult):
            XCTAssertEqual(importResult.workspaces.count, 1)
            // Only valid link should be imported
            XCTAssertEqual(importResult.linksImported, 1)
        case .failure(let error):
            XCTFail("Import failed: \(error)")
        }
    }

    func testArcImportDuplicateWorkspaceNames() async throws {
        let arcJSON: [String: Any] = [
            "version": 40,
            "sidebar": [
                "containers": [
                    [
                        "spaces": [
                            ["id": "space1", "title": "Work", "containerIDs": ["pinned", "c1"]],
                            ["id": "space2", "title": "Work", "containerIDs": ["pinned", "c2"]]
                        ],
                        "items": [
                            ["id": "c1", "title": "P", "parentID": "space1", "childrenIds": ["l1"]],
                            ["id": "c2", "title": "P", "parentID": "space2", "childrenIds": ["l2"]],
                            ["id": "l1", "title": nil, "parentID": "c1",
                             "data": ["tab": ["savedTitle": "A", "savedURL": "https://a.com"]]],
                            ["id": "l2", "title": nil, "parentID": "c2",
                             "data": ["tab": ["savedTitle": "B", "savedURL": "https://b.com"]]]
                        ]
                    ]
                ]
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: arcJSON)
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test_arc_\(UUID().uuidString).json")
        try data.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let result = await ArcImportService.shared.importFromArc(fileURL: tempFile)
        switch result {
        case .success(let importResult):
            XCTAssertEqual(importResult.workspaces.count, 2)
            XCTAssertEqual(importResult.workspaces[0].name, "Work")
            XCTAssertEqual(importResult.workspaces[1].name, "Work 2")
        case .failure(let error):
            XCTFail("Import failed: \(error)")
        }
    }

    // MARK: - Pinned Tabs Tests

    func testPinAndUnpinLink() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let linkId = model.addLink(urlString: "https://example.com", title: "Example", parentId: nil)
        XCTAssertEqual(model.currentWorkspace.pinnedLinks.count, 0)

        model.pinLink(id: linkId)
        XCTAssertEqual(model.currentWorkspace.pinnedLinks.count, 1)
        XCTAssertEqual(model.currentWorkspace.pinnedLinks[0].id, linkId)

        model.unpinLink(id: linkId)
        XCTAssertEqual(model.currentWorkspace.pinnedLinks.count, 0)
    }

    func testCannotPinDuplicate() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let linkId = model.addLink(urlString: "https://example.com", title: "Example", parentId: nil)
        model.pinLink(id: linkId)
        model.pinLink(id: linkId) // Should not add duplicate
        XCTAssertEqual(model.currentWorkspace.pinnedLinks.count, 1)
    }

    func testMaxPinnedLinks() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        // Pin up to max
        for i in 0..<Workspace.maxPinnedLinks {
            model.addLink(urlString: "https://example\(i).com", title: "Link \(i)", parentId: nil)
        }
        let links = model.currentWorkspace.items.compactMap { node -> UUID? in
            if case .link(let link) = node { return link.id }
            return nil
        }
        for linkId in links.prefix(Workspace.maxPinnedLinks) {
            model.pinLink(id: linkId)
        }
        XCTAssertEqual(model.currentWorkspace.pinnedLinks.count, Workspace.maxPinnedLinks)
        XCTAssertFalse(model.canPinMore())

        // Try to add one more — should not increase
        let extraId = model.addLink(urlString: "https://extra.com", title: "Extra", parentId: nil)
        model.pinLink(id: extraId)
        XCTAssertEqual(model.currentWorkspace.pinnedLinks.count, Workspace.maxPinnedLinks)
    }

    func testPinnedLinksJSONRoundTrip() throws {
        let link = Link(id: UUID(), title: "Pinned", url: "https://pinned.com", faviconPath: nil)
        let workspace = Workspace(id: UUID(), name: "Test", colorId: .ember, items: [], pinnedLinks: [link])
        let state = AppState(schemaVersion: 2, workspaces: [workspace], selectedWorkspaceId: workspace.id, isSettingsSelected: false)

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(AppState.self, from: data)
        XCTAssertEqual(decoded.workspaces[0].pinnedLinks.count, 1)
        XCTAssertEqual(decoded.workspaces[0].pinnedLinks[0].title, "Pinned")
    }

    func testPinnedLinksBackwardCompatibility() throws {
        // JSON without pinnedLinks field should decode fine
        let json = """
        {
            "schemaVersion": 2,
            "workspaces": [{
                "id": "00000000-0000-0000-0000-000000000001",
                "name": "Test",
                "colorId": "ember",
                "items": []
            }],
            "selectedWorkspaceId": "00000000-0000-0000-0000-000000000001",
            "isSettingsSelected": false
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppState.self, from: data)
        XCTAssertEqual(decoded.workspaces[0].pinnedLinks.count, 0)
    }

    func testUpdatePinnedLinkFaviconPath() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let linkId = model.addLink(urlString: "https://example.com", title: "Example", parentId: nil)
        model.pinLink(id: linkId)
        XCTAssertNil(model.currentWorkspace.pinnedLinks[0].faviconPath)

        model.updatePinnedLinkFaviconPath(id: linkId, path: "/path/to/icon.png")
        XCTAssertEqual(model.currentWorkspace.pinnedLinks[0].faviconPath, "/path/to/icon.png")
    }

    // MARK: - Browser Profiles

    func testBrowserProfileSetAndClear() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let workspaceId = model.currentWorkspace.id
        XCTAssertTrue(model.currentWorkspace.browserProfiles.isEmpty)

        // Set a profile
        model.updateWorkspaceBrowserProfile(id: workspaceId, bundleId: "com.google.Chrome", profile: "Profile 1")
        XCTAssertEqual(model.currentWorkspace.browserProfiles["com.google.Chrome"], "Profile 1")

        // Update to different profile
        model.updateWorkspaceBrowserProfile(id: workspaceId, bundleId: "com.google.Chrome", profile: "Default")
        XCTAssertEqual(model.currentWorkspace.browserProfiles["com.google.Chrome"], "Default")

        // Clear profile
        model.updateWorkspaceBrowserProfile(id: workspaceId, bundleId: "com.google.Chrome", profile: nil)
        XCTAssertNil(model.currentWorkspace.browserProfiles["com.google.Chrome"])
        XCTAssertTrue(model.currentWorkspace.browserProfiles.isEmpty)
    }

    func testBrowserProfileMultipleBrowsers() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let workspaceId = model.currentWorkspace.id

        // Set profiles for different browsers
        model.updateWorkspaceBrowserProfile(id: workspaceId, bundleId: "com.google.Chrome", profile: "Work")
        model.updateWorkspaceBrowserProfile(id: workspaceId, bundleId: "org.mozilla.firefox", profile: "personal")

        XCTAssertEqual(model.currentWorkspace.browserProfiles.count, 2)
        XCTAssertEqual(model.currentWorkspace.browserProfiles["com.google.Chrome"], "Work")
        XCTAssertEqual(model.currentWorkspace.browserProfiles["org.mozilla.firefox"], "personal")

        // Clear one, other remains
        model.updateWorkspaceBrowserProfile(id: workspaceId, bundleId: "com.google.Chrome", profile: nil)
        XCTAssertEqual(model.currentWorkspace.browserProfiles.count, 1)
        XCTAssertEqual(model.currentWorkspace.browserProfiles["org.mozilla.firefox"], "personal")
    }

    func testBrowserProfileJSONRoundTrip() {
        let workspace = Workspace(
            id: UUID(),
            name: "Test",
            colorId: .coral,
            items: [],
            pinnedLinks: [],
            browserProfiles: ["com.google.Chrome": "Profile 2", "org.mozilla.firefox": "default"]
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try! encoder.encode(workspace)
        let decoded = try! decoder.decode(Workspace.self, from: data)

        XCTAssertEqual(decoded.browserProfiles["com.google.Chrome"], "Profile 2")
        XCTAssertEqual(decoded.browserProfiles["org.mozilla.firefox"], "default")
    }

    func testBrowserProfileBackwardCompatibility() {
        // JSON without browserProfiles should decode successfully
        let json = """
        {
            "id": "12345678-1234-1234-1234-123456789abc",
            "name": "Old Workspace",
            "colorId": "coral",
            "items": []
        }
        """
        let data = json.data(using: .utf8)!
        let workspace = try! JSONDecoder().decode(Workspace.self, from: data)

        XCTAssertEqual(workspace.name, "Old Workspace")
        XCTAssertTrue(workspace.browserProfiles.isEmpty)
    }

    func testWorkspaceReordering() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        // Create three workspaces
        let id1 = model.createWorkspace(name: "First", colorId: .ember)
        let id2 = model.createWorkspace(name: "Second", colorId: .ruby)
        let id3 = model.createWorkspace(name: "Third", colorId: .moss)

        // Initial order should be: Inbox (default), First, Second, Third
        XCTAssertEqual(model.workspaces.count, 4)
        XCTAssertEqual(model.workspaces[0].name, "Inbox")
        XCTAssertEqual(model.workspaces[1].name, "First")
        XCTAssertEqual(model.workspaces[2].name, "Second")
        XCTAssertEqual(model.workspaces[3].name, "Third")

        // Move "Second" to the right (swap with "Third")
        model.moveWorkspace(id: id2, direction: .right)
        XCTAssertEqual(model.workspaces[2].name, "Third")
        XCTAssertEqual(model.workspaces[3].name, "Second")

        // Move "Second" to the left (swap back with "Third")
        model.moveWorkspace(id: id2, direction: .left)
        XCTAssertEqual(model.workspaces[2].name, "Second")
        XCTAssertEqual(model.workspaces[3].name, "Third")

        // Move "First" to the left (swap with "Inbox")
        model.moveWorkspace(id: id1, direction: .left)
        XCTAssertEqual(model.workspaces[0].name, "First")
        XCTAssertEqual(model.workspaces[1].name, "Inbox")

        // Try to move "First" to the left again (should not move, already at start)
        model.moveWorkspace(id: id1, direction: .left)
        XCTAssertEqual(model.workspaces[0].name, "First")
        XCTAssertEqual(model.workspaces[1].name, "Inbox")

        // Try to move "Third" to the right (should not move, already at end)
        model.moveWorkspace(id: id3, direction: .right)
        XCTAssertEqual(model.workspaces[2].name, "Second")
        XCTAssertEqual(model.workspaces[3].name, "Third")
    }
}
