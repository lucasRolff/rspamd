/*-
 * Copyright 2022 Vsevolod Stakhov
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#include "config.h"

#ifdef WITH_HYPERSCAN
#include <string>
#include "contrib/ankerl/unordered_dense.h"
#include "contrib/ankerl/svector.h"
#include "fmt/core.h"
#include "locked_file.hxx"
#include "hs.h"
#include "logger.h"
#include "locked_file.hxx"

#include <glob.h> /* for glob */
#include <unistd.h> /* for unlink */
#include <optional>
#include "unix-std.h"

#define msg_info_hyperscan(...)   rspamd_default_log_function (G_LOG_LEVEL_INFO, \
        "hyperscan", "", \
        RSPAMD_LOG_FUNC, \
        __VA_ARGS__)

#define msg_debug_hyperscan(...)  rspamd_conditional_debug_fast (NULL, NULL, \
        rspamd_hyperscan_log_id, "hyperscan", "", \
        RSPAMD_LOG_FUNC, \
        __VA_ARGS__)

INIT_LOG_MODULE_PUBLIC(hyperscan)

namespace rspamd::util {

class hs_known_files_cache {
private:
	// These fields are filled when we add new known cache files
	ankerl::svector<std::string, 4> cache_dirs;
	ankerl::svector<std::string, 8> cache_extensions;
	ankerl::unordered_dense::set<std::string> known_cached_files;
	bool need_cleanup = false;
private:
	hs_known_files_cache() = default;

	virtual ~hs_known_files_cache() {
		// Cleanup cache dir
		if (need_cleanup) {
			auto cleanup_dir = [&](std::string_view dir) -> void {
				for (const auto &ext : cache_extensions) {
					glob_t globbuf;

					auto glob_pattern = fmt::format("{}{}*.{}",
						dir, G_DIR_SEPARATOR_S, ext);
					memset(&globbuf, 0, sizeof(globbuf));

					if (glob(glob_pattern.c_str(), 0, nullptr, &globbuf) == 0) {
						for (auto i = 0; i < globbuf.gl_pathc; i++) {
							const auto *path = globbuf.gl_pathv[i];
							struct stat st;

							if (stat(path, &st) == -1) {
								msg_debug_hyperscan("cannot stat file %s: %s",
									path, strerror(errno));
								continue;
							}

							if (S_ISREG(st.st_mode)) {
								if (!known_cached_files.contains(path)) {
									msg_info_hyperscan("remove stale hyperscan file %s", path);
									unlink(path);
								}
								else {
									msg_debug_hyperscan("found known hyperscan file %s, size: %Hz",
										path, st.st_size);
								}
							}
						}
					}

					globfree(&globbuf);
				}
			};

			for (const auto &dir: cache_dirs) {
				cleanup_dir(dir);
			}
		}
	}
public:
	hs_known_files_cache(const hs_known_files_cache &) = delete;
	hs_known_files_cache(hs_known_files_cache &&) = delete;

	static auto get(bool need_cleanup) -> hs_known_files_cache& {
		static hs_known_files_cache *singleton = nullptr;

		if (singleton == nullptr) {
			singleton = new hs_known_files_cache;
			singleton->need_cleanup = need_cleanup;
		}

		return *singleton;
	}

	void add_cached_file(const raii_file &file) {
		auto dir = file.get_dir();
		auto ext = file.get_extension();

		if (std::find_if(cache_dirs.begin(), cache_dirs.end(),
			[&](const auto& item){ return item == dir; }) == std::end(cache_dirs)) {
			cache_dirs.emplace_back(std::string{dir});
		}
		if (std::find_if(cache_extensions.begin(), cache_extensions.end(),
			[&](const auto& item){ return item == ext; }) == std::end(cache_extensions)) {
			cache_extensions.emplace_back(std::string{ext});
		}

		known_cached_files.insert(file.get_name());
		msg_debug_hyperscan("added new known hyperscan file: %*s", (int)file.get_name().size(),
			file.get_name().data());
	}
};


/**
 * This is a higher level representation of the cached hyperscan file
 */
struct hs_shared_database {
	hs_database_t *db; /**< internal database (might be in a shared memory) */
	std::optional<raii_mmaped_file> maybe_map;

	~hs_shared_database() {
		if (!maybe_map) {
			hs_free_database(db);
		}
		// Otherwise, handled by maybe_map dtor
	}

	explicit hs_shared_database(raii_mmaped_file &&map, hs_database_t *db) : db(db), maybe_map(std::move(map)) {}
	explicit hs_shared_database(hs_database_t *db) : db(db), maybe_map(std::nullopt) {}
};

static auto
hs_shared_from_unserialized(raii_mmaped_file &&map) -> tl::expected<hs_shared_database, std::string>
{
	auto ptr = map.get_map();
	return tl::expected<hs_shared_database, std::string>{tl::in_place, std::move(map), (hs_database_t *)ptr};
}

static auto
hs_shared_from_serialized(raii_mmaped_file &&map) -> tl::expected<hs_shared_database, std::string>
{
	hs_database_t *target = nullptr;

	if (auto ret = hs_deserialize_database((const char *)map.get_map(), map.get_size(), &target); ret != HS_SUCCESS) {
		return tl::make_unexpected("cannot deserialize database");
	}

	return tl::expected<hs_shared_database, std::string>{tl::in_place, target};
}

auto load_cached_hs_file(const char *fname, bool need_cleanup) -> tl::expected<hs_shared_database, std::string>
{
	auto &hs_cache = hs_known_files_cache::get(need_cleanup);

	return raii_mmaped_file::mmap_shared(fname, O_RDONLY, PROT_READ)
		.and_then([&]<class T>(T &&cached_serialized) -> tl::expected<hs_shared_database, std::string> {
#if defined(HS_MAJOR) && defined(HS_MINOR) && HS_MAJOR >= 5 && HS_MINOR >= 4
			auto unserialized_fname = fmt::format("{}.unser", fname);
			auto unserialized_file = raii_locked_file::create(unserialized_fname.c_str(), O_CREAT | O_RDWR | O_EXCL,
				00644)
				.and_then([&](auto &&new_file_locked) -> tl::expected<raii_file, std::string> {
					auto tmpfile_pattern = fmt::format("{}{}hsmp-XXXXXXXXXXXXXXXXXX",
						cached_serialized.get_file().get_dir(), G_DIR_SEPARATOR);
					auto tmpfile = raii_locked_file::mkstemp(tmpfile_pattern.data(), O_CREAT | O_RDWR | O_EXCL,
						00644);

					if (!tmpfile) {
						return tl::make_unexpected(tmpfile.error());
					}
					else {
						auto &tmpfile_checked = tmpfile.value();
						std::size_t unserialized_size;

						hs_serialized_database_size((const char *)cached_serialized.get_map(),
							cached_serialized.get_size(), &unserialized_size);

						msg_debug("multipattern: create new database in %s; %Hz size",
							tmpfile_pattern.data(), unserialized_size);
						void *buf;
						posix_memalign(&buf, 16, unserialized_size);
						if (buf == NULL) {
							return tl::make_unexpected("Cannot allocate memory");
						}

						// Store owned string
						auto tmpfile_name = std::string{tmpfile_checked.get_name()};

						if (auto ret = hs_deserialize_database_at((const char *)cached_serialized.get_map(),
								cached_serialized.get_size(), (hs_database_t *) buf); ret != HS_SUCCESS) {
							return tl::make_unexpected(
								fmt::format("cannot deserialize hyperscan database: {}", ret));
						}
						else {
							if (write(tmpfile_checked.get_fd(), buf, unserialized_size) == -1) {
								free(buf);
								return tl::make_unexpected(fmt::format("cannot write to {}: {}",
									tmpfile_name, ::strerror(errno)));
							}
							else {
								free(buf);

								/*
								 * Unlink target file before renaming to avoid
								 * race condition.
								 * So what we have is that `new_file_locked`
								 * will have flock on that file, so it will be
								 * replaced after unlink safely, and also unlocked.
								 */
								(void) unlink(unserialized_fname.c_str());
								if (rename(tmpfile_name.c_str(),
									unserialized_fname.c_str()) == -1) {
									if (errno != EEXIST) {
										msg_err("cannot rename %s -> %s: %s",
											tmpfile_name.c_str(),
											unserialized_fname.c_str(),
											strerror(errno));
									}
								}
								else {
									/* Unlock file but mark it as immortal first to avoid deletion */
									tmpfile_checked.make_immortal();
									(void) tmpfile_checked.unlock();
								}
							}
						}
						/* Reopen in RO mode */
						return raii_file::open(unserialized_fname.c_str(), O_RDONLY);
					};
				})
				.or_else([&](auto unused) -> tl::expected<raii_file, std::string> {
					// Cannot create file, so try to open it in RO mode
					return raii_file::open(unserialized_fname.c_str(), O_RDONLY);
				});

			hs_cache.add_cached_file(cached_serialized.get_file());

			if (unserialized_file.has_value()) {

				auto &unserialized_checked = unserialized_file.value();
				hs_cache.add_cached_file(unserialized_checked);

				if (unserialized_checked.get_size() == 0) {
					/*
					 * This is a case when we have a file that is currently
					 * being created by another process.
					 * We cannot use it!
					 */
					return hs_shared_from_serialized(std::forward<T>(cached_serialized));
				}
				else {
					return raii_mmaped_file::mmap_shared(std::move(unserialized_checked), PROT_READ)
						.and_then([&]<class U>(U &&mmapped_unserialized) -> auto {
							return hs_shared_from_unserialized(std::forward<U>(mmapped_unserialized));
						});
				}
			}
			else {
				return hs_shared_from_serialized(std::forward<T>(cached_serialized));
			}
#else // defined(HS_MAJOR) && defined(HS_MINOR) && HS_MAJOR >= 5 && HS_MINOR >= 4
			hs_cache.add_cached_file(cached_serialized.get_file());
			return hs_shared_from_serialized(std::forward<T>(cached_serialized));
#endif // defined(HS_MAJOR) && defined(HS_MINOR) && HS_MAJOR >= 5 && HS_MINOR >= 4
		});
}
} // namespace rspamd::util


#endif // WITH_HYPERSCAN