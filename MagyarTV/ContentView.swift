import SwiftUI
import AVKit
import Combine
import os.log
import Network

struct ContentView: View {
  @State private var selectedTab = "M4"
  @State private var showChannelOverlay = false
  
  var body: some View {
    ZStack {
      TabView(selection: $selectedTab) {
        ChannelView(channel: "mtv1live", isActive: selectedTab == "M1")
          .tabItem {
            Label("M1", systemImage: "1.circle")
          }
          .tag("M1")
        
//        ChannelView(channel: "mtv2live", isActive: selectedTab == "M2")
//          .tabItem {
//            Label("M2", systemImage: "2.circle")
//          }
//          .tag("M2")
//        
//        ChannelView(channel: "mtv3live", isActive: selectedTab == "M3")
//          .tabItem {
//            Label("M3", systemImage: "3.circle")
//          }
//          .tag("M3")
        
        ChannelView(channel: "mtv4live", isActive: selectedTab == "M4")
          .tabItem {
            Label("M4", systemImage: "4.circle")
          }
          .tag("M4")
      }
      .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
      
      if showChannelOverlay {
        VStack {
          Spacer()
          Text("Channel: \(selectedTab)")
            .padding()
            .background(Color.black.opacity(0.7))
            .foregroundColor(.white)
            .cornerRadius(10)
            .transition(.move(edge: .bottom))
        }
        .animation(.easeInOut, value: showChannelOverlay)
      }
    }
    .onChange(of: selectedTab) { _ in
      showChannelOverlay = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        showChannelOverlay = false
      }
    }
  }
}

struct ChannelView: View {
  @StateObject private var viewModel: VideoPlayerViewModel
  let isActive: Bool
  
  init(channel: String, isActive: Bool) {
    _viewModel = StateObject(wrappedValue: VideoPlayerViewModel(channel: channel))
    self.isActive = isActive
  }
  
  var body: some View {
    ZStack {
      if let player = viewModel.player {
        CustomVideoPlayer(player: player)
          .edgesIgnoringSafeArea(.all)
      } else {
        ProgressView()
      }
    }
    .onAppear {
      viewModel.startNetworkMonitoring()
    }
    .onDisappear {
      viewModel.stopNetworkMonitoring()
    }
    .onChange(of: isActive) { newValue in
      if newValue {
        viewModel.play()
      } else {
        viewModel.pause()
      }
    }
    .alert(item: $viewModel.error) { error in
      Alert(title: Text("Error"), message: Text(error.localizedDescription), dismissButton: .default(Text("OK")))
    }
  }
}

class VideoPlayerViewModel: ObservableObject {
  @Published var player: AVPlayer?
  @Published var error: VideoPlayerError?
  
  private var cancellables = Set<AnyCancellable>()
  private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TVOSVideoPlayer", category: "VideoPlayer")
  private let networkMonitor = NWPathMonitor()
  private let channel: String
  
  init(channel: String) {
    self.channel = channel
  }
  
  private var videoURL: String {
    "https://player.mediaklikk.hu/playernew/player.php?video=\(channel)&noflash=yes"
  }
  
  func startNetworkMonitoring() {
    networkMonitor.pathUpdateHandler = { [weak self] path in
      guard let self = self else { return }
      DispatchQueue.main.async {
        if path.status == .satisfied {
          self.loadVideo()
        } else {
          self.error = .networkUnavailable
        }
      }
    }
    networkMonitor.start(queue: DispatchQueue.global())
  }
  
  func stopNetworkMonitoring() {
    networkMonitor.cancel()
  }
  
  func play() {
    if player == nil {
      loadVideo()
    } else {
      player?.seek(to: .zero)
      player?.play()
    }
  }
  
  func pause() {
    player?.pause()
  }
  
  func loadVideo() {
    logger.info("Starting video loading process")
    guard let url = URL(string: videoURL) else {
      logger.error("Invalid URL: \(self.videoURL)")
      self.error = .invalidURL
      return
    }
    
    let startTime = DispatchTime.now()
    
    logger.debug("Initiating network request to: \(url.absoluteString)")
    
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.addValue("player.mediaklikk.hu", forHTTPHeaderField: "Host")
    request.addValue("iframe", forHTTPHeaderField: "Sec-Fetch-Dest")
    request.addValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
    request.addValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
    request.addValue("https://m4sport.hu/", forHTTPHeaderField: "Referer")
    request.addValue("cross-site", forHTTPHeaderField: "Sec-Fetch-Site")
    request.addValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
    request.addValue("en-GB,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    request.addValue("u=0, i", forHTTPHeaderField: "Priority")
    request.addValue("keep-alive", forHTTPHeaderField: "Connection")
    
    URLSession.shared.dataTaskPublisher(for: request)
      .tryMap { data, response -> (String, HTTPURLResponse) in
        guard let httpResponse = response as? HTTPURLResponse else {
          throw VideoPlayerError.invalidHTTPResponse(statusCode: -1)
        }
        guard 200...299 ~= httpResponse.statusCode else {
          throw VideoPlayerError.invalidHTTPResponse(statusCode: httpResponse.statusCode)
        }
        guard let mimeType = httpResponse.mimeType, mimeType == "text/html" else {
          throw VideoPlayerError.unexpectedContentType
        }
        guard let htmlContent = String(data: data, encoding: .utf8) else {
          print(data)
          throw VideoPlayerError.invalidHTMLContent
        }
        return (htmlContent, httpResponse)
      }
      .tryMap { htmlContent, _ -> URL in
        switch self.extractVideoURL(from: htmlContent) {
          case .success(let url):
            return url
          case .failure(let error):
            throw error
        }
      }
      .receive(on: DispatchQueue.main)
      .sink { [weak self] completion in
        guard let self = self else { return }
        if case .failure(let error) = completion {
          self.error = (error as? VideoPlayerError) ?? .networkError(error)
          self.logger.error("Completion error: \(error.localizedDescription)")
        }
      } receiveValue: { [weak self] videoURL in
        guard let self = self else { return }
        
        self.logger.info("Successfully extracted video URL: \(videoURL.absoluteString)")
        self.player = AVPlayer(url: videoURL)
        self.player?.play()
        
        self.setupAVPlayerErrorObservation()
        
        let endTime = DispatchTime.now()
        let nanoTime = endTime.uptimeNanoseconds - startTime.uptimeNanoseconds
        let timeInterval = Double(nanoTime) / 1_000_000_000
        
        self.logger.info("Video loaded and started playing in \(timeInterval) seconds")
      }
      .store(in: &cancellables)
  }
  
  private func setupAVPlayerErrorObservation() {
    NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: player?.currentItem, queue: .main) { [weak self] notification in
      guard let self = self else { return }
      if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
        self.logger.error("Failed to play video: \(error.localizedDescription)")
        self.error = .playbackError(error)
      }
    }
  }
  
  private func extractVideoURL(from htmlContent: String) -> Result<URL, VideoPlayerError> {
    let pattern = #""file": "(.*?)""#
    
    do {
      let regex = try NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators)
      let matches = regex.matches(in: htmlContent, options: [], range: NSRange(location: 0, length: htmlContent.utf16.count))
      
      for match in matches {
        guard let range = Range(match.range(at: 1), in: htmlContent) else { continue }
        
        var urlString = String(htmlContent[range])
        
        // Unescape the URL
        urlString = urlString.replacingOccurrences(of: "%5C/", with: "/")
        urlString = urlString.replacingOccurrences(of: "\\", with: "")
        urlString = urlString.removingPercentEncoding ?? urlString
        
        // Remove any trailing parameters (like ?v=5iip:149.200.69.2)
        if let questionMarkIndex = urlString.firstIndex(of: "?") {
          urlString = String(urlString[..<questionMarkIndex])
        }
        
        // Check if the URL doesn't contain "bumper"
        if !urlString.lowercased().contains("bumper") {
          guard let url = URL(string: urlString) else {
            logger.error("Invalid video URL extracted: \(urlString)")
            continue // Try the next match if this URL is invalid
          }
          
          logger.debug("Extracted video URL: \(url.absoluteString)")
          return .success(url)
        }
      }
      
      // If we've gone through all matches and haven't found a suitable URL
      logger.error("No suitable video URL found in HTML content")
      return .failure(.videoURLNotFound)
    } catch {
      logger.error("Regex error: \(error.localizedDescription)")
      return .failure(.regexError(error))
    }
  }
}

struct CustomVideoPlayer: UIViewControllerRepresentable {
  let player: AVPlayer
  
  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let controller = AVPlayerViewController()
    controller.player = player
    controller.showsPlaybackControls = true
    return controller
  }
  
  func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}

enum VideoPlayerError: Error, Identifiable {
  case invalidURL
  case networkError(Error)
  case invalidHTMLContent
  case videoURLNotFound
  case invalidVideoURL
  case regexError(Error)
  case invalidHTTPResponse(statusCode: Int)
  case playbackError(Error)
  case unexpectedContentType
  case networkUnavailable
  
  var id: String { localizedDescription }
  
  var localizedDescription: String {
    switch self {
      case .invalidURL:
        return "Invalid URL for fetching HTML content"
      case .networkError(let error):
        return "Network error: \(error.localizedDescription)"
      case .invalidHTMLContent:
        return "Invalid HTML content received"
      case .videoURLNotFound:
        return "Video URL not found in HTML content"
      case .invalidVideoURL:
        return "Invalid video URL extracted from HTML"
      case .regexError(let error):
        return "Regex error: \(error.localizedDescription)"
      case .invalidHTTPResponse(let statusCode):
        return "Invalid HTTP response. Status code: \(statusCode)"
      case .playbackError(let error):
        return "Playback error: \(error.localizedDescription)"
      case .unexpectedContentType:
        return "Unexpected content type received"
      case .networkUnavailable:
        return "Network is unavailable"
    }
  }
}
