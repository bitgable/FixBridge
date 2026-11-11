import Combine
import MapKit

@MainActor
final class MapPointPickerViewModel: ObservableObject {
    struct SearchResult: Identifiable {
        let id = UUID()
        let name: String
        let address: String?
        let coordinate: CLLocationCoordinate2D

        init?(_ item: MKMapItem) {
            if #available(macOS 26.0, *) {
                coordinate = item.location.coordinate
                address = item.address?.fullAddress
            } else {
                coordinate = item.placemark.coordinate
                address = item.placemark.title
            }
            guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            name = item.name ?? address ?? String(localized: "Selected Location")
        }
    }

    private static let maximumQueryBytes = 512

    @Published var selectedCoordinate: CLLocationCoordinate2D?
    @Published var query = ""
    @Published private(set) var searchResults: [SearchResult] = []
    @Published private(set) var searchMessage: String?
    @Published private var activeSearch: MKLocalSearch?

    var isSearching: Bool { activeSearch != nil }
    var showsSearchDropdown: Bool { isSearching || searchMessage != nil || !searchResults.isEmpty }
    var canSearch: Bool {
        !isSearching && (queryTooLong || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var queryTooLong: Bool {
        query.utf8.prefix(Self.maximumQueryBytes + 1).count > Self.maximumQueryBytes
    }

    init(initialCoordinate: CLLocationCoordinate2D?) {
        selectedCoordinate = initialCoordinate
    }

    func select(_ result: SearchResult) {
        selectedCoordinate = result.coordinate
        clearSearch()
    }

    func clearSearch() {
        activeSearch?.cancel()
        activeSearch = nil
        searchResults = []
        searchMessage = nil
    }

    func search() {
        guard !queryTooLong else {
            clearSearch()
            searchMessage = String(localized: "Enter a shorter address or place name.")
            return
        }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, activeSearch == nil else { return }
        clearSearch()
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = [.address, .pointOfInterest]
        let search = MKLocalSearch(request: request)
        activeSearch = search
        Task {
            do {
                let response = try await search.start()
                guard activeSearch === search else { return }
                searchResults = response.mapItems.compactMap(SearchResult.init)
                if searchResults.isEmpty { searchMessage = String(localized: "No matching places found.") }
            } catch {
                guard activeSearch === search else { return }
                if (error as? MKError)?.code == .placemarkNotFound {
                    searchMessage = String(localized: "No matching places found.")
                } else {
                    searchMessage = String(localized: "Apple Maps search is unavailable. Try again.")
                }
            }
            activeSearch = nil
        }
    }
}
