//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2023-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Crypto
import Logging
@preconcurrency import SystemPackage

#if canImport(AsyncHTTPClient)
  import AsyncHTTPClient
#endif

public func withQueryEngine(
  _ fileSystem: some AsyncFileSystem,
  _ logger: Logger,
  cacheLocation: SQLite.Location,
  _ body: @Sendable (QueryEngine) async throws -> Void
) async throws {
  let engine = QueryEngine(
    fileSystem,
    logger,
    cacheLocation: cacheLocation
  )

  try await withAsyncThrowing {
    try await body(engine)
  } defer: {
    try await engine.shutDown()
  }
}

/// Cacheable computations engine. Currently the engine makes an assumption that computations produce same results for
/// the same query values and write results to a single file path.
public actor QueryEngine {
  private(set) var cacheHits = 0
  private(set) var cacheMisses = 0

  public let fileSystem: any AsyncFileSystem

  #if canImport(AsyncHTTPClient)
  public let httpClient = HTTPClient()
  #endif

  public let observabilityScope: Logger
  private let resultsCache: SQLiteBackedCache
  private var isShutDown = false

  /// Creates a new instance of the ``QueryEngine`` actor. Requires an explicit call
  /// to ``QueryEngine//shutdown`` before the instance is deinitialized. The recommended approach to resource
  /// management is to place `engine.shutDown()` when the engine is no longer used, but is not deinitialized yet.
  /// - Parameter fileSystem: Implementation of a file system this engine should use.
  /// - Parameter cacheLocation: Location of cache storage used by the engine.
  /// - Parameter logger: Logger to use during queries execution.
  init(
    _ fileSystem: any AsyncFileSystem,
    _ observabilityScope: Logger,
    cacheLocation: SQLite.Location = .memory
  ) {
    self.fileSystem = fileSystem
    self.observabilityScope = observabilityScope
    self.resultsCache = SQLiteBackedCache(tableName: "cache_table", location: cacheLocation, observabilityScope)
  }

  public func shutDown() async throws {
    precondition(!self.isShutDown, "`QueryEngine/shutDown` should be called only once")
    try self.resultsCache.close()

    #if canImport(AsyncHTTPClient)
    try await httpClient.shutdown()
    #endif

    self.isShutDown = true
  }

  deinit {
    let isShutDown = self.isShutDown
    precondition(
      isShutDown,
      "`QueryEngine/shutDown` should be called explicitly on instances of `Engine` before deinitialization"
    )
  }

  /// Executes a given query if no cached result of it is available. Otherwise fetches the result from engine's cache.
  /// - Parameter query: A query value to execute.
  /// - Returns: A file path to query's result recorded in a file.
  public subscript(_ query: some Query) -> FileCacheRecord {
    get async throws {
      let hashEncoder = HashEncoder<SHA512>()
      try hashEncoder.encode(query.cacheKey)
      let key = hashEncoder.finalize()

      if let fileRecord = try resultsCache.get(key, as: FileCacheRecord.self) {
        let fileHash = try await self.fileSystem.withOpenReadableFile(fileRecord.path) {
          var hashFunction = SHA512()
          try await $0.hash(with: &hashFunction)
          return hashFunction.finalize().description
        }

        if fileHash == fileRecord.hash {
          self.cacheHits += 1
          return fileRecord
        }
      }

      self.cacheMisses += 1
      let resultPath = try await query.run(engine: self)

      let resultHash = try await self.fileSystem.withOpenReadableFile(resultPath) {
        var hashFunction = SHA512()
        try await $0.hash(with: &hashFunction)
        return hashFunction.finalize().description
      }
      let result = FileCacheRecord(path: resultPath, hash: resultHash)

      // FIXME: update `SQLiteBackedCache` to store `resultHash` directly instead of relying on string conversions
      try self.resultsCache.set(key, to: result)

      return result
    }
  }
}
