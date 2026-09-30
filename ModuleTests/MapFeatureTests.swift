import MapFeature
import Testing

struct MapFeatureTests {
    @Test func sameNamedPlacesKeepTheirCampusIdentity() throws {
        let first = try #require(CampusMapPlaceCatalog.place(campusName: "中关村校区", classroom: "中关村体育馆北厅140"))
        let second = try #require(CampusMapPlaceCatalog.place(campusName: "良乡校区", classroom: "良乡体育馆篮球场"))
        #expect(first.name == second.name)
        #expect(first.campus == .zhongguancun)
        #expect(second.campus == .liangxiang)
        #expect(first.id != second.id)
    }

    @Test func requestsCarryTheResolvedPlaceIdentity() throws {
        let place = try #require(CampusMapPlaceCatalog.place(campusName: "良乡校区", classroom: "良乡体育馆篮球场"))
        let request = CampusMapLocationRequest(courseName: "体育", places: [place])
        #expect(request.courseName == "体育")
        #expect(request.places.map(\.id) == [place.id])
    }
}
