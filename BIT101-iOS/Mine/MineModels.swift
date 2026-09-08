//
//  MineModels.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Foundation

/// “我的”页个人信息接口模型。
///
/// `MineUserInfo` 服务于“我的主页”和他人主页的资料卡。
/// 模型包含基础用户信息、关注关系和是否本人这些关系态字段。
struct MineUserInfo: Decodable {
    /// 当前主页主体用户。
    let user: GalleryUser
    /// 当前主页用户关注的人数。
    let followingNum: Int
    /// 当前主页用户的粉丝人数。
    let followerNum: Int
    /// 当前登录用户关注该用户时为 `true`。
    let following: Bool
    /// 该用户关注当前登录用户时为 `true`。
    let follower: Bool
    /// 该资料页属于当前登录用户时为 `true`。
    let own: Bool
}

/// “我的”页子列表的加载状态。
///
/// `MineLoadStatus` 把列表页的“空闲 / 加载中 / 已加载 / 失败”状态统一成一个枚举，
/// 列表页使用这个枚举驱动空态、错误态和 loading 态。
enum MineLoadStatus: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

/// 粉丝、关注、帖子列表共用的分页状态。
///
/// 关注列表、粉丝列表和帖子列表使用不同的元素类型，分页语义保持一致。
/// 这个泛型状态结构统一复用分页状态。
struct MinePagedState<Item> {
    /// 当前已加载的列表项。
    var items: [Item] = []
    /// 列表整体加载状态。
    var status: MineLoadStatus = .idle
    /// 下一页页码。首页统一从 `0` 开始请求。
    var nextPage = 0
    /// 列表正在请求下一页时为 `true`。
    var isLoadingMore = false
    /// 后端提供更多数据时为 `true`；值为 `false` 时停止分页。
    var canLoadMore = true
}

extension MinePagedState: PagedItemsState {}
