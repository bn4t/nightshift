import CoreLocation
import MapKit
import NightshiftCore
import Observation

/// City search with live suggestions (Apple Maps). Only runs while the user types.
@MainActor
@Observable
final class LocationSearch: NSObject, MKLocalSearchCompleterDelegate {
    struct Suggestion: Identifiable, Equatable {
        let id: Int
        let title: String
        let subtitle: String
    }

    var query = "" {
        didSet {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                completer.cancel()
                completions = []
                suggestions = []
            } else {
                completer.queryFragment = trimmed
            }
        }
    }

    private(set) var suggestions: [Suggestion] = []

    @ObservationIgnored private let completer = MKLocalSearchCompleter()
    @ObservationIgnored private var completions: [MKLocalSearchCompletion] = []

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            completions = Array(self.completer.results.prefix(5))
            suggestions = completions.enumerated().map {
                Suggestion(id: $0.offset, title: $0.element.title, subtitle: $0.element.subtitle)
            }
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated { suggestions = [] }
    }

    /// Resolves a suggestion to coordinates and a display name.
    func resolve(_ suggestion: Suggestion, completion: @escaping (Coordinate, String) -> Void) {
        guard completions.indices.contains(suggestion.id) else { return }
        let name = suggestion.subtitle.isEmpty ? suggestion.title : "\(suggestion.title), \(suggestion.subtitle)"
        MKLocalSearch(request: MKLocalSearch.Request(completion: completions[suggestion.id])).start { response, _ in
            guard let item = response?.mapItems.first else { return }
            let c: CLLocationCoordinate2D
            if #available(macOS 26, *) { c = item.location.coordinate } else { c = item.placemark.coordinate }
            let coordinate = Coordinate(latitude: c.latitude, longitude: c.longitude)
            MainActor.assumeIsolated { completion(coordinate, name) }
        }
    }

    /// "Paris, France" for a coordinate, when the OS supports it.
    static func placeName(for coordinate: Coordinate, completion: @escaping (String?) -> Void) {
        guard #available(macOS 26, *),
              let request = MKReverseGeocodingRequest(
                  location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
        else { completion(nil); return }
        request.getMapItems { items, _ in
            completion(items?.first?.addressRepresentations?.cityWithContext)
        }
    }
}
