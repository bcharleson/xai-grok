import Foundation
import Combine

class GrokAPIService: ObservableObject {
    private let baseURL = "https://api.x.ai/v1"
    private var apiKey: String?
    private let session = URLSession.shared
    
    func setAPIKey(_ key: String) {
        self.apiKey = key
    }
    
    func sendMessage(messages: [Message], model: String = "grok-beta", temperature: Double = 0.7, stream: Bool = true) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let apiKey = apiKey, !apiKey.isEmpty else {
                        throw APIError.missingAPIKey
                    }
                    
                    let apiMessages = messages.map { APIMessage(role: $0.role.rawValue, content: $0.content) }
                    let request = ChatCompletionRequest(
                        model: model,
                        messages: apiMessages,
                        temperature: temperature,
                        maxTokens: nil,
                        stream: stream
                    )
                    
                    var urlRequest = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.httpBody = try JSONEncoder().encode(request)
                    
                    if stream {
                        let (bytes, response) = try await session.bytes(for: urlRequest)
                        
                        guard let httpResponse = response as? HTTPURLResponse else {
                            throw APIError.invalidResponse
                        }
                        
                        if httpResponse.statusCode != 200 {
                            throw APIError.httpError(httpResponse.statusCode)
                        }
                        
                        for try await line in bytes.lines {
                            if line.hasPrefix("data: ") {
                                let jsonString = String(line.dropFirst(6))
                                if jsonString == "[DONE]" {
                                    continuation.finish()
                                    return
                                }
                                
                                if let data = jsonString.data(using: .utf8),
                                   let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
                                   let content = chunk.choices.first?.delta.content {
                                    continuation.yield(content)
                                }
                            }
                        }
                    } else {
                        let (data, response) = try await session.data(for: urlRequest)
                        
                        guard let httpResponse = response as? HTTPURLResponse else {
                            throw APIError.invalidResponse
                        }
                        
                        if httpResponse.statusCode != 200 {
                            throw APIError.httpError(httpResponse.statusCode)
                        }
                        
                        let completion = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
                        if let content = completion.choices.first?.message.content {
                            continuation.yield(content)
                        }
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

enum APIError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case httpError(Int)
    case decodingError
    
    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "API key is missing. Please add your xAI API key in settings."
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .decodingError:
            return "Failed to decode response"
        }
    }
}