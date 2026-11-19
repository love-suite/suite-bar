import Testing
@testable import ExplorerCore

@Suite struct RecentAppsTests {
    @Test func theLastActivatedComesFirst() {
        var recent = RecentApps()
        recent.activated(1)
        recent.activated(2)
        recent.activated(3)
        recent.activated(1)
        #expect(recent.order == [1, 3, 2])
    }

    @Test func quitAppsLeaveAndUnseenOnesFollow() {
        var recent = RecentApps([3, 1, 2])
        recent.terminated(1)
        #expect(recent.order == [3, 2])
        #expect(recent.ordered([2, 5, 3, 4]) == [3, 2, 5, 4])
    }
}

@Suite struct AppSwitcherStateTests {
    @Test func opensOnThePreviousApp() {
        let state = AppSwitcherState(apps: [10, 20, 30])
        #expect(state.selected == 20)
        #expect(AppSwitcherState(apps: [10, 20, 30], backwards: true).selected == 30)
        #expect(AppSwitcherState(apps: [10]).selected == 10)
        #expect(AppSwitcherState(apps: []).selected == nil)
    }

    @Test func goesRoundBothWays() {
        var state = AppSwitcherState(apps: [10, 20, 30])
        state.next()
        #expect(state.selected == 30)
        state.next()
        #expect(state.selected == 10)
        state.previous()
        #expect(state.selected == 30)
        state.select(0)
        #expect(state.selected == 10)
        state.select(7)
        #expect(state.selected == 10)
    }

    @Test func keysMapLikeMacOS() {
        #expect(AppSwitcherKey(keyCode: AppSwitcherKey.tab, shift: false) == .next)
        #expect(AppSwitcherKey(keyCode: AppSwitcherKey.tab, shift: true) == .previous)
        #expect(AppSwitcherKey(keyCode: AppSwitcherKey.grave, shift: true) == .previous)
        #expect(AppSwitcherKey(keyCode: AppSwitcherKey.rightArrow, shift: false) == .next)
        #expect(AppSwitcherKey(keyCode: AppSwitcherKey.leftArrow, shift: false) == .previous)
        #expect(AppSwitcherKey(keyCode: AppSwitcherKey.escape, shift: false) == .cancel)
        #expect(AppSwitcherKey(keyCode: 0, shift: false) == .ignore)
    }
}
