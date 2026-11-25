import CoreLocation
import NightshiftCore

/// One-shot "use my current location". Only city-level accuracy is needed.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    enum Failure: LocalizedError {
        case denied
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .denied: "Location access is off. Allow it in System Settings → Privacy & Security → Location Services, or enter coordinates manually."
            case let .unavailable(reason): reason
            }
        }
    }

    private let manager = CLLocationManager()
    private var completion: ((Result<Coordinate, Failure>) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func request(_ completion: @escaping (Result<Coordinate, Failure>) -> Void) {
        self.completion = completion
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: finish(.failure(.denied))
        default: manager.requestLocation()
        }
    }

    private func finish(_ result: Result<Coordinate, Failure>) {
        completion?(result)
        completion = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            guard completion != nil else { return }
            switch status {
            case .notDetermined: break
            case .denied, .restricted: finish(.failure(.denied))
            default: self.manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let c = locations.last?.coordinate else { return }
        let coordinate = Coordinate(latitude: c.latitude, longitude: c.longitude)
        MainActor.assumeIsolated { finish(.success(coordinate)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated { finish(.failure(.unavailable(message))) }
    }
}
