import Foundation
import MapKit

/// Apple Maps for the agent, answered on the phone with MapKit: no tapping through the Maps app. Results come back
/// as text the model reads (names, addresses, distances, travel times).
enum MapsTools {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// Places matching `query`, near `near` when given (a place name or address), up to `limit`.
    static func search(_ query: String, near: String?, limit: Int = 6) async throws -> String {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        var origin: CLLocation?
        if let near, !near.isEmpty {
            let center = try await place(near)
            origin = center.placemark.location
            request.region = MKCoordinateRegion(center: center.placemark.coordinate, latitudinalMeters: 20_000, longitudinalMeters: 20_000)
        }
        let items = try await MKLocalSearch(request: request).start().mapItems.prefix(max(1, min(limit, 10)))
        guard !items.isEmpty else { return "No places found for \"\(query)\"." }
        return items.enumerated().map { i, item in
            var line = "\(i + 1). \(item.name ?? "?") — \(address(item.placemark))"
            if let origin, let here = item.placemark.location {
                line += String(format: " (%.1f km away)", here.distance(from: origin) / 1000)
            }
            if let phone = item.phoneNumber { line += ", phone \(phone)" }
            return line
        }.joined(separator: "\n")
    }

    /// Route from one place to another: distance and travel time for driving, walking or transit.
    static func directions(from: String, to: String, mode: String?) async throws -> String {
        let request = MKDirections.Request()
        request.source = try await place(from)
        request.destination = try await place(to)
        switch mode?.lowercased() {
        case "walking", "walk": request.transportType = .walking
        case "transit", "public transport": request.transportType = .transit
        default: request.transportType = .automobile
        }
        if request.transportType == .transit {
            let eta = try await MKDirections(request: request).calculateETA()
            return String(format: "By transit from %@ to %@: about %d min, %.1f km.", from, to, Int(eta.expectedTravelTime / 60), eta.distance / 1000)
        }
        guard let route = try await MKDirections(request: request).calculate().routes.first else { return "No route found from \(from) to \(to)." }
        let steps = route.steps.map(\.instructions).filter { !$0.isEmpty }.prefix(12)
        return String(format: "%@ from %@ to %@: about %d min, %.1f km, via %@.", request.transportType == .walking ? "Walking" : "Driving",
                      from, to, Int(route.expectedTravelTime / 60), route.distance / 1000, route.name)
            + (steps.isEmpty ? "" : "\nSteps: " + steps.joined(separator: "; "))
    }

    private static func place(_ text: String) async throws -> MKMapItem {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        guard let item = try await MKLocalSearch(request: request).start().mapItems.first else { throw Failure(description: "Maps could not find \"\(text)\".") }
        return item
    }

    private static func address(_ p: MKPlacemark) -> String {
        [p.subThoroughfare.map { "\($0) \(p.thoroughfare ?? "")" } ?? p.thoroughfare, p.locality, p.administrativeArea, p.country]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
