// The cooker's C interface to LightUSD. See cn_usd.h.
#include "cn_usd.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <string>
#include <unordered_map>
#include <vector>

#include "asset-resolution.hh"
#include "composition-graph.hh"
#include "composition.hh"
#include "layer.hh"
#include "lightusd.hh"
#include "pcp/layer-registry.hh"
#include "tydra/render-data-converter.hh"
#include "tydra/render-data.hh"
#include "usdGeom.hh"
#include "xform.hh"

namespace tydra = lightusd::tydra;

struct Cn_Usd {
	std::string error;
	std::string warnings;
	lightusd::Stage stage;
	tydra::RenderScene scene;
	// The root layer's sublayers, resolved: the cooker watches the USD files under their folders.
	std::vector<std::string> layers;
	// Pre-order, so a parent comes before its children.
	struct Flat_Node {
		const tydra::Node *node;
		int32_t parent;
	};
	std::vector<Flat_Node> nodes;
	// Whether each node is a prototype or under one.
	std::vector<int32_t> node_prototype;
	struct Instancer {
		const lightusd::GeomPointInstancer *prim;
		std::string name, path;
		lightusd::value::matrix4d world;
		std::vector<std::string> prototypes;
		std::vector<std::vector<Cn_Usd_Prototype_Mesh>> meshes;
		int32_t point_count;
		bool nested;
	};
	std::vector<Instancer> instancers;
	// The current cn_usd_mesh's corners.
	std::vector<float> positions, normals, uv0, uv1, colors;
	std::vector<Cn_Usd_Subset> subsets;
	std::vector<std::string> subset_names;
	std::vector<std::string> resolved;
	// Each light's texture's file, resolved as a texture's is.
	std::vector<std::string> light_resolved;
	// Each material's first copy: the first material whose inputs and textures are the same (see material_key).
	std::vector<int32_t> material_alias;
};

static Cn_Usd_String str(const std::string &s) {
	return {s.data(), s.size()};
}

static void copy_matrix(const lightusd::value::matrix4d &m, double out[16]) {
	for (int r = 0; r < 4; r++) {
		for (int c = 0; c < 4; c++) {
			out[r * 4 + c] = m.m[r][c];
		}
	}
}

static void flatten(Cn_Usd *usd, const tydra::Node &node, int32_t parent) {
	int32_t self = int32_t(usd->nodes.size());
	usd->nodes.push_back({&node, parent});
	for (const tydra::Node &child : node.children) {
		flatten(usd, child, self);
	}
}

// is_under is whether a prim path is `root` or below it.
static bool is_under(const std::string &path, const std::string &root) {
	return path.size() >= root.size() && path.compare(0, root.size(), root) == 0 &&
	       (path.size() == root.size() || path[root.size()] == '/');
}

// find_instancers lists the point instancers under a prim, with their world matrices, which it composes from each
// prim's xformOps as it goes down.
static void find_instancers(Cn_Usd *usd, const lightusd::Prim &prim, const std::string &parent_path,
                            const lightusd::value::matrix4d &parent_world) {
	std::string path = parent_path + "/" + std::string(prim.element_name());
	bool reset = false;
	lightusd::value::matrix4d local = lightusd::GetLocalTransform(prim, &reset);
	lightusd::value::matrix4d world = reset ? local : lightusd::value::Mult(local, parent_world);
	if (const lightusd::GeomPointInstancer *pi = prim.as<lightusd::GeomPointInstancer>()) {
		Cn_Usd::Instancer in;
		in.prim = pi;
		in.name = std::string(prim.element_name());
		in.path = path;
		in.world = world;
		if (pi->prototypes) {
			if (pi->prototypes->is_path()) {
				in.prototypes.push_back(pi->prototypes->targetPath.full_path_name());
			} else if (pi->prototypes->is_pathvector()) {
				for (const lightusd::Path &p : pi->prototypes->targetPathVector) {
					in.prototypes.push_back(p.full_path_name());
				}
			}
		}
		std::vector<bool> mask;
		std::string err;
		lightusd::ComputeMaskAtTime(*pi, lightusd::value::TimeCode::Default(), &mask, &err);
		in.point_count = int32_t(std::count(mask.begin(), mask.end(), true));
		in.nested = false;
		usd->instancers.push_back(std::move(in));
	}
	for (const lightusd::Prim &child : prim.children()) {
		find_instancers(usd, child, path, world);
	}
}

// An asset path joined to the folder that it is relative to. It stays in the form that the stage's path was given in,
// so the cooker can name files relative to the stage: canonical paths would expand a Windows short name such as
// ALICSZ~1, which the temporary folder has.
static std::string resolve_relative(const std::string &base_dir, const std::string &asset) {
	std::string a = asset;
	std::replace(a.begin(), a.end(), '\\', '/');
	std::filesystem::path p(a);
	if (p.is_relative()) {
		p = std::filesystem::path(base_dir) / p;
	}
	return p.lexically_normal().generic_string();
}

// The token or string value of `prop` on `prim`, if it has one.
static bool string_property(const lightusd::Prim &prim, const std::string &prop, std::string *out) {
	const std::map<std::string, lightusd::Property> *props = nullptr;
	if (const lightusd::NodeGraph *graph = prim.as<lightusd::NodeGraph>()) {
		props = &graph->props;
	} else if (const lightusd::Material *material = prim.as<lightusd::Material>()) {
		props = &material->props;
	}
	if (!props) {
		return false;
	}
	auto it = props->find(prop);
	if (it == props->end() || !it->second.is_attribute()) {
		return false;
	}
	const lightusd::Attribute &attr = it->second.get_attribute();
	if (auto token = attr.get_value<lightusd::value::token>()) {
		*out = token->str();
		return true;
	}
	if (auto s = attr.get_value<std::string>()) {
		*out = *s;
		return true;
	}
	return false;
}

// Tydra cannot read an input of a NodeGraph or Material, so a primvar reader whose `inputs:varname` connects to one,
// as 3ds Max writes Sponza's (`inputs:varname.connect = </root/mtl/X.inputs:frame:st>`), fails its whole material.
// The reader gets the value the connection leads to instead.
static void resolve_varname_connections(lightusd::Stage &stage, lightusd::Prim &prim, int *fixed) {
	if (lightusd::Shader *shader = prim.get_data().as<lightusd::Shader>()) {
		if (auto *reader = shader->value.as<lightusd::UsdPrimvarReader_float2>()) {
			if (reader->varname.is_connection()) {
				const lightusd::Path &target = reader->varname.get_connections()[0];
				const lightusd::Prim *owner = nullptr;
				std::string value;
				if (stage.find_prim_at_path(lightusd::Path(target.prim_part(), ""), owner, nullptr) && owner &&
				    string_property(*owner, target.prop_part(), &value)) {
					reader->varname.clear_connections();
					reader->varname.set_value(lightusd::Animatable<std::string>(value));
					(*fixed)++;
				}
			}
		}
	}
	for (lightusd::Prim &child : prim.children()) {
		resolve_varname_connections(stage, child, fixed);
	}
}

// The prim that an absolute path names on the composed stage, if there is one.
static const lightusd::Prim *stage_prim(const lightusd::Stage &stage, const std::string &path) {
	const lightusd::Prim *prim = nullptr;
	if (!stage.find_prim_at_path(lightusd::Path(path, ""), prim, nullptr)) {
		return nullptr;
	}
	return prim;
}

// LightUSD composes a reference's prims under the referencing prim but leaves the paths that their relationships and
// connections target as the referenced layer authored them. Jungle Ruins' plant prototypes reference prims of their
// *_classes.usda layers, so a prototype's mesh binds </root/ShrubSorrel_01_Translucent/Looks/MI_...>, and the
// material's shaders connect to each other there, where the material is at
// </World/.../Prototypes/ShrubSorrel_04_Translucent/Looks/MI_...>, and Tydra loses the material or fails the stage.
// remap_target finds such a target's prim on the composed stage: its path less its first elements, the longest rest
// first, under each ancestor of the prim that holds the property, the nearest first. A target that is on the stage
// stays.
static bool remap_target(const lightusd::Stage &stage, const std::string &owner, const lightusd::Path &target,
                         bool material, lightusd::Path *out) {
	std::string prim_path = target.prim_part();
	const lightusd::Prim *found = stage_prim(stage, prim_path);
	if (found && (!material || found->as<lightusd::Material>())) {
		return false;
	}
	std::vector<std::string> elements;
	for (size_t at = 1; at < prim_path.size();) {
		size_t end = prim_path.find('/', at);
		end = end == std::string::npos ? prim_path.size() : end;
		elements.push_back(prim_path.substr(at, end - at));
		at = end + 1;
	}
	for (size_t first = 1; first < elements.size(); first++) {
		std::string rest;
		for (size_t k = first; k < elements.size(); k++) {
			rest += "/" + elements[k];
		}
		for (size_t slash = owner.rfind('/'); slash != std::string::npos && slash > 0; slash = owner.rfind('/', slash - 1)) {
			std::string candidate = owner.substr(0, slash) + rest;
			const lightusd::Prim *prim = stage_prim(stage, candidate);
			if (prim && (!material || prim->as<lightusd::Material>())) {
				*out = lightusd::Path(candidate, target.prop_part());
				return true;
			}
		}
	}
	return false;
}

static void remap_binding(const lightusd::Stage &stage, const std::string &owner,
                          lightusd::RelationshipProperty &binding, int *fixed) {
	lightusd::Path remapped;
	if (binding.authored() && binding.relationship().is_path() &&
	    remap_target(stage, owner, binding.relationship().targetPath, true, &remapped)) {
		binding.set(remapped);
		(*fixed)++;
	}
}

// remap_paths remaps a list of connections, and gives whether it changed.
static bool remap_paths(const lightusd::Stage &stage, const std::string &owner, std::vector<lightusd::Path> &paths,
                        int *fixed) {
	bool changed = false;
	for (lightusd::Path &p : paths) {
		lightusd::Path remapped;
		if (remap_target(stage, owner, p, false, &remapped)) {
			p = remapped;
			changed = true;
			(*fixed)++;
		}
	}
	return changed;
}

template <typename A>
static void remap_input(const lightusd::Stage &stage, const std::string &owner, A &input, int *fixed) {
	std::vector<lightusd::Path> paths = input.get_connections();
	if (remap_paths(stage, owner, paths, fixed)) {
		input.set_connections(paths);
	}
}

template <typename T>
static void remap_output(const lightusd::Stage &stage, const std::string &owner, lightusd::TypedConnection<T> &output,
                         int *fixed) {
	std::vector<lightusd::Path> paths = output.get_connections();
	if (remap_paths(stage, owner, paths, fixed)) {
		output.set(paths);
	}
}

template <typename T>
static void remap_reader(const lightusd::Stage &stage, const std::string &owner, lightusd::Shader *shader, int *fixed) {
	if (auto *reader = shader->value.as<lightusd::UsdPrimvarReader<T>>()) {
		remap_input(stage, owner, reader->varname, fixed);
	}
}

// remap_targets repairs each mesh's and geometry subset's material bindings, each material's outputs, and the inputs
// of each UsdPreviewSurface, UsdUVTexture, UsdTransform2d and primvar reader, the shaders that the cooker reads (see
// remap_target). A composed prim's absolute_path is not set, so the walk builds each prim's path from its parent's.
static void remap_targets(const lightusd::Stage &stage, lightusd::Prim &prim, const std::string &parent, int *fixed) {
	auto name = prim.element_name();
	std::string path = parent + "/" + std::string(name.data(), name.size());
	if (lightusd::GeomMesh *mesh = prim.get_data().as<lightusd::GeomMesh>()) {
		remap_binding(stage, path, mesh->materialBinding, fixed);
		remap_binding(stage, path, mesh->materialBindingPreview, fixed);
	} else if (lightusd::GeomSubset *subset = prim.get_data().as<lightusd::GeomSubset>()) {
		remap_binding(stage, path, subset->materialBinding, fixed);
		remap_binding(stage, path, subset->materialBindingPreview, fixed);
	} else if (lightusd::Material *material = prim.get_data().as<lightusd::Material>()) {
		remap_output(stage, path, material->surface, fixed);
		remap_output(stage, path, material->displacement, fixed);
	} else if (lightusd::Shader *shader = prim.get_data().as<lightusd::Shader>()) {
		if (auto *s = shader->value.as<lightusd::UsdPreviewSurface>()) {
			for (auto *input : {&s->metallic, &s->clearcoat, &s->clearcoatRoughness, &s->roughness, &s->opacity,
			                    &s->opacityThreshold, &s->ior, &s->displacement, &s->occlusion}) {
				remap_input(stage, path, *input, fixed);
			}
			remap_input(stage, path, s->diffuseColor, fixed);
			remap_input(stage, path, s->emissiveColor, fixed);
			remap_input(stage, path, s->specularColor, fixed);
			remap_input(stage, path, s->useSpecularWorkflow, fixed);
			remap_input(stage, path, s->normal, fixed);
		} else if (auto *texture = shader->value.as<lightusd::UsdUVTexture>()) {
			remap_input(stage, path, texture->st, fixed);
			remap_input(stage, path, texture->file, fixed);
		} else if (auto *transform = shader->value.as<lightusd::UsdTransform2d>()) {
			remap_input(stage, path, transform->in, fixed);
		}
		remap_reader<float>(stage, path, shader, fixed);
		remap_reader<lightusd::value::float2>(stage, path, shader, fixed);
		remap_reader<lightusd::value::float3>(stage, path, shader, fixed);
		remap_reader<lightusd::value::float4>(stage, path, shader, fixed);
		remap_reader<int>(stage, path, shader, fixed);
	}
	for (lightusd::Prim &child : prim.children()) {
		remap_targets(stage, child, path, fixed);
	}
}

// The prim at an absolute path such as /root/a/b, found by its elements' names.
static lightusd::Prim *find_prim(std::vector<lightusd::Prim> &prims, const std::string &path) {
	size_t at = path.find_first_not_of('/');
	if (at == std::string::npos) {
		return nullptr;
	}
	size_t end = path.find('/', at);
	std::string name = path.substr(at, end == std::string::npos ? std::string::npos : end - at);
	for (lightusd::Prim &prim : prims) {
		auto element = prim.element_name();
		if (std::string(element.data(), element.size()) == name) {
			return end == std::string::npos ? &prim : find_prim(prim.children(), path.substr(end));
		}
	}
	return nullptr;
}

// The prim path in Tydra's "Mesh conversion failed: /path" error, or empty.
static std::string failed_mesh(const std::string &err) {
	const std::string marker = "Mesh conversion failed: ";
	size_t at = err.rfind(marker);
	if (at == std::string::npos) {
		return {};
	}
	at += marker.size();
	size_t end = err.find_first_of(" \r\n", at);
	return err.substr(at, end == std::string::npos ? std::string::npos : end - at);
}

// The line of an error that says what went wrong, without the source location that LightUSD puts first. Tydra's error
// for a mesh has a line for each level that it passed through, and the ones that name the mesh say no more.
static std::string first_line(const std::string &err) {
	std::string line;
	size_t at = 0;
	while (at < err.size()) {
		size_t end = err.find('\n', at);
		end = end == std::string::npos ? err.size() : end;
		std::string candidate = err.substr(at, end - at);
		if (line.empty()) {
			line = candidate;
		}
		if (candidate.find("Mesh conversion failed") == std::string::npos &&
		    candidate.find("Visit function returned") == std::string::npos &&
		    candidate.find_first_not_of(" \r") != std::string::npos) {
			line = candidate;
			break;
		}
		at = end + 1;
	}
	// "<file>:<function>():<line> <message>"
	at = line.find("():");
	if (at != std::string::npos) {
		size_t space = line.find(' ', at);
		if (space != std::string::npos) {
			line = line.substr(space + 1);
		}
	}
	return line;
}

// Tydra stops at the first mesh it cannot convert, so one bad mesh would lose the whole stage. A mesh that failed is
// repaired and the stage converted again. At the first level its authored normals go, which is what an exporter most
// often gets wrong (Sponza's curtains have fewer normal indices than points), and the cooker makes its own. At the
// second the mesh becomes an empty Xform and is left out.
struct Repair {
	std::string path;
	int level;
};

static bool apply_repair(lightusd::Stage &stage, const Repair &repair) {
	lightusd::Prim *prim = find_prim(stage.root_prims(), repair.path);
	if (!prim) {
		return false;
	}
	if (repair.level == 1) {
		lightusd::GeomMesh *mesh = prim->get_data().as<lightusd::GeomMesh>();
		if (!mesh) {
			return false;
		}
		mesh->normals = decltype(mesh->normals){};
		mesh->props.erase("primvars:normals");
		mesh->props.erase("primvars:normals:indices");
		return true;
	}
	lightusd::Xform empty;
	auto name = prim->element_name();
	empty.name = std::string(name.data(), name.size());
	prim->get_data() = empty;
	prim->prim_type_name() = "Xform";
	return true;
}

static const lightusd::Layer *load_layer(void *userdata, const std::string &asset_path, const std::string &cwp,
                                         std::string *warn, std::string *err) {
	auto *c = static_cast<std::pair<lightusd::pcp::LayerRegistry *, lightusd::AssetResolutionResolver *> *>(userdata);
	return c->first->GetOrLoad(*c->second, asset_path, cwp, warn, err);
}

// material_key is everything that the cooker reads of a material but its name and path, its textures' files and
// sampling included, as bytes.
static std::string material_key(Cn_Usd *usd, int32_t index) {
	Cn_Usd_Material m;
	cn_usd_material(usd, index, &m);
	std::string key;
	auto bytes = [&key](const void *p, size_t n) { key.append(static_cast<const char *>(p), n); };
	auto text = [&key](Cn_Usd_String s) {
		key.append(s.ptr ? s.ptr : "", s.len);
		key += '\0';
	};
	auto input = [&](const Cn_Usd_Input &in) {
		bytes(&in.channel, sizeof(in.channel));
		bytes(in.value, sizeof(in.value));
		if (in.texture < 0) {
			key += '-';
			return;
		}
		Cn_Usd_Texture t;
		cn_usd_texture(usd, in.texture, &t);
		text(t.resolved.len ? t.resolved : t.asset);
		text(t.uv_name);
		for (int32_t v : {t.color_space, t.wrap_s, t.wrap_t, t.has_transform}) {
			bytes(&v, sizeof(v));
		}
		bytes(t.scale, sizeof(t.scale));
		bytes(t.bias, sizeof(t.bias));
		bytes(t.transform_scale, sizeof(t.transform_scale));
		bytes(&t.transform_rotation, sizeof(t.transform_rotation));
		bytes(t.transform_translation, sizeof(t.transform_translation));
	};
	bytes(&m.preview_surface, sizeof(m.preview_surface));
	bytes(&m.specular_workflow, sizeof(m.specular_workflow));
	for (const Cn_Usd_Input *in :
	     {&m.diffuse, &m.emissive, &m.metallic, &m.roughness, &m.opacity, &m.normal, &m.occlusion}) {
		input(*in);
	}
	bytes(&m.opacity_threshold, sizeof(m.opacity_threshold));
	return key;
}

// alias_material is a material's first copy, or -1 for none.
static int32_t alias_material(Cn_Usd *usd, int32_t material) {
	if (material < 0 || size_t(material) >= usd->material_alias.size()) {
		return material;
	}
	return usd->material_alias[size_t(material)];
}

// Composes the stage as LightUSD's large-scene loader does (src/large-scene-loader.cc), but with the root layer's
// sublayers found in their own folders: the loader leaves the root layer's working path empty, so a relative sublayer
// resolves against the process's working directory.
static bool compose_stage(const std::string &file, lightusd::Stage *stage, std::string *warn, std::string *err) {
	constexpr size_t MAX_ASSET_MB = 8192;
	std::string base_dir = std::filesystem::path(file).parent_path().generic_string();
	lightusd::AssetResolutionResolver resolver;
	resolver.set_current_working_path(base_dir);
	resolver.set_search_paths({base_dir});
	resolver.set_max_asset_bytes_in_mb(MAX_ASSET_MB);
	resolver.set_max_file_descriptors(1024);

	lightusd::Layer root;
	{
		lightusd::USDLoadOptions options;
		options.max_allowed_asset_size_in_mb = MAX_ASSET_MB;
		if (!lightusd::LoadLayerFromFile(file, &root, warn, err, options)) {
			return false;
		}
	}
	// LightUSD's file lookup refuses a path with "..", and its path check takes the drive off an absolute Windows path,
	// but a stage that wraps files kept elsewhere, as a sample's downloads, sublayers them with "..". Each root sublayer
	// becomes its file's name, found in its folder, which joins the root layer's search paths.
	std::vector<std::string> folders = {base_dir};
	for (lightusd::SubLayer &sublayer : root.metas().subLayers) {
		std::filesystem::path resolved(resolve_relative(base_dir, sublayer.assetPath.GetAssetPath()));
		std::string folder = resolved.parent_path().generic_string();
		if (std::find(folders.begin(), folders.end(), folder) == folders.end()) {
			folders.push_back(folder);
		}
		sublayer.assetPath = lightusd::value::AssetPath(resolved.filename().generic_string());
	}
	root.set_asset_resolution_state(base_dir, folders);
	lightusd::Layer flat;
	{
		lightusd::SublayersCompositionOptions options;
		options.allow_parent_relative_paths = true;
		options.max_depth = 1024;
		if (!lightusd::CompositeSublayers(resolver, root, &flat, warn, err, options)) {
			return false;
		}
	}
	lightusd::pcp::LayerRegistry registry;
	std::pair<lightusd::pcp::LayerRegistry *, lightusd::AssetResolutionResolver *> context(&registry, &resolver);
	lightusd::CompositionGraphOptions options;
	options.detect_instances = true;
	options.allow_parent_relative_paths = true;
	options.max_depth = 1024;
	// Large scenes have millions of composed prims, as the large-scene loader allows.
	options.max_composed_prims = 64u * 1024u * 1024u;
	options.max_arc_nodes = 64u * 1024u * 1024u;
	options.max_namespace_depth = 8192;
	options.load_layer_fn = &load_layer;
	options.load_layer_userdata = &context;
	auto graph = lightusd::CompositionGraph::Compose(resolver, flat, options);
	if (!graph) {
		if (err) {
			*err += "cannot compose the stage: " + graph.error();
		}
		return false;
	}
	return graph->BuildStage(stage, warn, err);
}

// Composes the stage, and makes the changes Tydra needs.
static bool load_stage(const std::string &file, const std::vector<Repair> &repairs, lightusd::Stage *stage,
                       std::string *warn, std::string *err) {
	if (!compose_stage(file, stage, warn, err)) {
		return false;
	}
	int fixed = 0;
	for (lightusd::Prim &root : stage->root_prims()) {
		// The targets first, so a primvar reader's varname connects to where its value is.
		remap_targets(*stage, root, "", &fixed);
		resolve_varname_connections(*stage, root, &fixed);
	}
	for (const Repair &repair : repairs) {
		apply_repair(*stage, repair);
	}
	return true;
}

extern "C" Cn_Usd *cn_usd_open(const char *path, const Cn_Usd_Options *options) {
	Cn_Usd *usd = new Cn_Usd();
	std::string file(path);
	std::string warn, err;

	// The root layer alone, for its sublayers. Composition reads it again.
	{
		lightusd::Layer root;
		if (!lightusd::LoadLayerFromFile(file, &root, &warn, &err)) {
			usd->error = err.empty() ? "cannot read the root layer" : err;
			return usd;
		}
		std::string base_dir = std::filesystem::path(file).parent_path().generic_string();
		for (const auto &sublayer : root.metas().subLayers) {
			std::string resolved = resolve_relative(base_dir, sublayer.assetPath.GetAssetPath());
			std::error_code ec;
			if (!std::filesystem::exists(resolved, ec)) {
				usd->error = "missing layer " + resolved;
				return usd;
			}
			usd->layers.push_back(resolved);
		}
	}

	// Tydra leaves an asset path relative to the layer that authored it, without saying which layer that was, so a
	// texture resolves against every folder that holds a layer: the root's, and each one under its sublayers'.
	std::string base_dir = std::filesystem::path(file).parent_path().generic_string();
	std::vector<std::string> search = {base_dir};
	for (const std::string &layer : usd->layers) {
		std::filesystem::path dir = std::filesystem::path(layer).parent_path();
		std::error_code ec;
		std::vector<std::string> found = {dir.generic_string()};
		for (auto it = std::filesystem::recursive_directory_iterator(dir, ec);
		     !ec && it != std::filesystem::recursive_directory_iterator(); it.increment(ec)) {
			std::string ext = it->path().extension().string();
			std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
			if (ext == ".usd" || ext == ".usda" || ext == ".usdc") {
				found.push_back(it->path().parent_path().generic_string());
			}
		}
		for (const std::string &d : found) {
			if (std::find(search.begin(), search.end(), d) == search.end()) {
				search.push_back(d);
			}
		}
	}
	std::vector<Repair> repairs;
	std::string repaired;
	for (int attempt = 0;; attempt++) {
		// Conversion takes from the stage as it goes (mesh_config.lowmem), so each attempt composes it again.
		if (attempt > 0) {
			usd->stage = lightusd::Stage();
		}
		if (!load_stage(file, repairs, &usd->stage, &warn, &err)) {
			usd->error = err.empty() ? "cannot compose the stage" : err;
			usd->warnings = warn;
			return usd;
		}
		tydra::RenderSceneConverter converter;
		tydra::RenderSceneConverterEnv env(usd->stage);
		env.mesh_config.triangulate = true;
		env.mesh_config.build_vertex_indices = false;
		// The cooker generates MikkTSpace tangents itself, the same as for glTF.
		env.mesh_config.compute_tangents_and_binormals = false;
		env.mesh_config.lowmem = true;
		env.scene_config.load_texture_assets = false;
		env.scene_config.expand_point_instancers = options && options->point_instancers;
		env.material_config.allow_backslash_in_asset_path = true;
		env.material_config.allow_missing_asset = true;
		env.set_search_paths(search);
		usd->scene = {};
		if (converter.ConvertToRenderScene(env, &usd->scene)) {
			warn += converter.GetWarning();
			break;
		}
		std::string failed = failed_mesh(converter.GetError());
		auto known = std::find_if(repairs.begin(), repairs.end(), [&](const Repair &r) { return r.path == failed; });
		bool repairable = !failed.empty() && attempt < 256 && (known == repairs.end() || known->level < 2) &&
		                  find_prim(usd->stage.root_prims(), failed) != nullptr;
		if (!repairable) {
			usd->error = converter.GetError();
			if (usd->error.empty()) {
				usd->error = "cannot convert the stage";
			}
			warn += converter.GetWarning();
			break;
		}
		std::string reason = first_line(converter.GetError());
		if (known == repairs.end()) {
			repairs.push_back({failed, 1});
			repaired += "mesh " + failed + " cannot be converted (" + reason + "), so its normals are made instead\n";
		} else {
			known->level = 2;
			repaired += "mesh " + failed + " is left out: " + reason + "\n";
		}
	}
	warn += repaired;
	{
		size_t at = 0;
		while (at < warn.size()) {
			size_t end = warn.find('\n', at);
			end = end == std::string::npos ? warn.size() : end + 1;
			std::string line = warn.substr(at, end - at);
			at = end;
			if (line.find_first_not_of(" \r\n") == std::string::npos) {
				continue;
			}
			// Tydra looks for animation on every property and warns about each one that a prim lacks: a line per
			// property of every prim, hundreds of kilobytes on Sponza, none of it about a problem.
			if (line.find("ExtractPrimPropertyAnimation") != std::string::npos) {
				continue;
			}
			usd->warnings += line;
		}
	}
	if (!usd->scene.nodes.empty()) {
		flatten(usd, usd->scene.nodes[usd->scene.default_root_node], -1);
		// Roots other than the default one, such as a stage with no defaultPrim.
		for (size_t i = 0; i < usd->scene.nodes.size(); i++) {
			if (i != usd->scene.default_root_node) {
				flatten(usd, usd->scene.nodes[i], -1);
			}
		}
	}
	// The point instancers, and the meshes of their prototypes, which Tydra converts as meshes of the scene.
	for (const lightusd::Prim &root : usd->stage.root_prims()) {
		find_instancers(usd, root, "", lightusd::value::matrix4d::identity());
	}
	{
		std::unordered_map<std::string, const lightusd::value::matrix4d *> world_of;
		for (const Cn_Usd::Flat_Node &n : usd->nodes) {
			world_of[n.node->abs_path] = &n.node->global_matrix;
		}
		auto world = [&](const std::string &path) {
			auto it = world_of.find(path);
			return it != world_of.end() ? *it->second : lightusd::value::matrix4d::identity();
		};
		for (Cn_Usd::Instancer &in : usd->instancers) {
			in.meshes.resize(in.prototypes.size());
			for (size_t p = 0; p < in.prototypes.size(); p++) {
				lightusd::value::matrix4d inverse_root = lightusd::value::matrix4d::identity();
				lightusd::inverse(world(in.prototypes[p]), inverse_root);
				for (size_t m = 0; m < usd->scene.meshes.size(); m++) {
					const std::string &mesh_path = usd->scene.meshes[m].abs_path;
					if (!is_under(mesh_path, in.prototypes[p])) {
						continue;
					}
					Cn_Usd_Prototype_Mesh pm = {};
					pm.mesh = int32_t(m);
					// Row vectors: the mesh's world is its pose under the root, then the root's world.
					copy_matrix(lightusd::value::Mult(world(mesh_path), inverse_root), pm.local);
					in.meshes[p].push_back(pm);
				}
			}
		}
		for (Cn_Usd::Instancer &in : usd->instancers) {
			for (const Cn_Usd::Instancer &outer : usd->instancers) {
				for (const std::string &p : outer.prototypes) {
					in.nested = in.nested || is_under(in.path, p);
				}
			}
		}
		usd->node_prototype.assign(usd->nodes.size(), 0);
		for (size_t i = 0; i < usd->nodes.size(); i++) {
			for (const Cn_Usd::Instancer &in : usd->instancers) {
				for (const std::string &p : in.prototypes) {
					if (is_under(usd->nodes[i].node->abs_path, p)) {
						usd->node_prototype[i] = 1;
					}
				}
			}
		}
	}
	// Each texture's file, resolved against the layer that authored it if Tydra left it relative, and each light's.
	auto resolve = [&search](std::string asset) -> std::string {
		std::replace(asset.begin(), asset.end(), '\\', '/');
		std::error_code ec;
		for (const std::string &dir : search) {
			std::string candidate = resolve_relative(dir, asset);
			if (std::filesystem::exists(candidate, ec)) {
				return candidate;
			}
		}
		return {};
	};
	usd->resolved.resize(usd->scene.textures.size());
	for (size_t i = 0; i < usd->scene.textures.size(); i++) {
		const tydra::UVTexture &t = usd->scene.textures[i];
		if (t.texture_image_id < 0 || size_t(t.texture_image_id) >= usd->scene.images.size()) {
			continue;
		}
		usd->resolved[i] = resolve(usd->scene.images[size_t(t.texture_image_id)].asset_identifier);
	}
	usd->light_resolved.resize(usd->scene.lights.size());
	for (size_t i = 0; i < usd->scene.lights.size(); i++) {
		if (!usd->scene.lights[i].textureFile.empty()) {
			usd->light_resolved[i] = resolve(usd->scene.lights[i].textureFile);
		}
	}
	// A referenced prim's material is a material of its own under each prim that references it, as each of Jungle
	// Ruins' plant prototypes has a copy of its class's: copies that read the same are one, so their meshes share.
	std::unordered_map<std::string, int32_t> first_material;
	usd->material_alias.resize(usd->scene.materials.size());
	for (size_t i = 0; i < usd->scene.materials.size(); i++) {
		auto it = first_material.emplace(material_key(usd, int32_t(i)), int32_t(i)).first;
		usd->material_alias[i] = it->second;
	}
	return usd;
}

extern "C" void cn_usd_close(Cn_Usd *usd) {
	delete usd;
}

extern "C" Cn_Usd_String cn_usd_error(Cn_Usd *usd) {
	return str(usd->error);
}

extern "C" Cn_Usd_String cn_usd_warnings(Cn_Usd *usd) {
	return str(usd->warnings);
}

extern "C" void cn_usd_info(Cn_Usd *usd, Cn_Usd_Info *info) {
	*info = {};
	const tydra::SceneMetadata &meta = usd->scene.meta;
	info->up = meta.upAxis == "Z" ? CN_USD_UP_Z : CN_USD_UP_Y;
	info->meters_per_unit = meta.metersPerUnit > 0 ? meta.metersPerUnit : 1.0;
	info->node_count = int32_t(usd->nodes.size());
	info->mesh_count = int32_t(usd->scene.meshes.size());
	info->material_count = int32_t(usd->scene.materials.size());
	info->texture_count = int32_t(usd->scene.textures.size());
	info->instance_count = int32_t(usd->scene.instances.size());
	info->light_count = int32_t(usd->scene.lights.size());
	info->layer_count = int32_t(usd->layers.size());
	info->instancer_count = int32_t(usd->instancers.size());
}

extern "C" Cn_Usd_String cn_usd_layer(Cn_Usd *usd, int32_t index) {
	return str(usd->layers[size_t(index)]);
}

extern "C" void cn_usd_node(Cn_Usd *usd, int32_t index, Cn_Usd_Node *out) {
	const Cn_Usd::Flat_Node &flat = usd->nodes[size_t(index)];
	const tydra::Node &node = *flat.node;
	*out = {};
	out->parent = flat.parent;
	out->mesh = -1;
	out->visible = 1;
	out->prototype = usd->node_prototype[size_t(index)];
	out->name = str(node.prim_name);
	out->path = str(node.abs_path);
	switch (node.category) {
	case tydra::NodeCategory::Group:
		out->kind = CN_USD_NODE_GROUP;
		break;
	case tydra::NodeCategory::Geom:
		out->kind = node.nodeType == tydra::NodeType::Mesh && node.id >= 0 ? CN_USD_NODE_MESH : CN_USD_NODE_OTHER;
		break;
	case tydra::NodeCategory::Camera:
		out->kind = CN_USD_NODE_CAMERA;
		break;
	case tydra::NodeCategory::Light:
		out->kind = CN_USD_NODE_LIGHT;
		break;
	default:
		out->kind = CN_USD_NODE_OTHER;
		break;
	}
	if (out->kind == CN_USD_NODE_MESH) {
		out->mesh = node.id;
	}
	copy_matrix(node.local_matrix, out->local);
	copy_matrix(node.global_matrix, out->world);
}

extern "C" void cn_usd_instance(Cn_Usd *usd, int32_t index, Cn_Usd_Instance *out) {
	const tydra::RenderInstance &instance = usd->scene.instances[size_t(index)];
	*out = {};
	out->mesh = instance.mesh_id;
	out->material = alias_material(usd, instance.material_id);
	out->visible = instance.visible;
	out->path = str(instance.abs_path);
	copy_matrix(instance.global_matrix, out->world);
}

extern "C" void cn_usd_instancer(Cn_Usd *usd, int32_t index, Cn_Usd_Instancer *out) {
	const Cn_Usd::Instancer &in = usd->instancers[size_t(index)];
	*out = {};
	out->name = str(in.name);
	out->path = str(in.path);
	copy_matrix(in.world, out->world);
	out->prototype_count = int32_t(in.prototypes.size());
	out->point_count = in.point_count;
	out->nested = in.nested;
}

extern "C" int32_t cn_usd_prototype_meshes(Cn_Usd *usd, int32_t instancer, int32_t prototype,
                                           const Cn_Usd_Prototype_Mesh **meshes) {
	const std::vector<Cn_Usd_Prototype_Mesh> &list = usd->instancers[size_t(instancer)].meshes[size_t(prototype)];
	*meshes = list.data();
	return int32_t(list.size());
}

extern "C" int32_t cn_usd_instancer_points(Cn_Usd *usd, int32_t instancer, int32_t *prototypes, double *matrices) {
	const Cn_Usd::Instancer &in = usd->instancers[size_t(instancer)];
	const double time = lightusd::value::TimeCode::Default();
	std::vector<lightusd::value::matrix4d> xforms;
	std::vector<bool> mask;
	std::string err;
	if (!lightusd::ComputeInstanceTransformsAtTime(*in.prim, time, lightusd::value::TimeSampleInterpolationType::Linear,
	                                               &xforms, &err) ||
	    !lightusd::ComputeMaskAtTime(*in.prim, time, &mask, &err)) {
		return 0;
	}
	std::vector<int32_t> indices = in.prim->get_protoIndices(time);
	if (indices.size() != xforms.size() || mask.size() != xforms.size()) {
		return 0;
	}
	int32_t at = 0;
	for (size_t i = 0; i < xforms.size(); i++) {
		if (!mask[i]) {
			continue;
		}
		if (at >= in.point_count) {
			return 0;
		}
		prototypes[at] = indices[i];
		copy_matrix(xforms[i], &matrices[size_t(at) * 16]);
		at++;
	}
	return at == in.point_count;
}

// Reads element `i` of an attribute with `width` floats per element, whatever its variability. False when the
// attribute is not floats.
static bool attribute_floats(const tydra::VertexAttribute &a, uint32_t width, size_t corner, size_t vertex,
                             size_t face, float *out) {
	size_t item;
	if (a.is_facevarying()) {
		item = corner;
	} else if (a.is_vertex()) {
		item = vertex;
	} else if (a.is_uniform()) {
		item = face;
	} else {
		item = 0;
	}
	if (!a.indices.empty()) {
		if (item >= a.indices.size()) {
			return false;
		}
		item = a.indices[item];
	}
	size_t stride = a.stride_bytes();
	if (a.format_size() != width * sizeof(float) || (item + 1) * stride > a.data.size()) {
		return false;
	}
	std::memcpy(out, a.data.data() + item * stride, width * sizeof(float));
	return true;
}

extern "C" int32_t cn_usd_mesh(Cn_Usd *usd, int32_t index, Cn_Usd_Mesh *out) {
	const tydra::RenderMesh &mesh = usd->scene.meshes[size_t(index)];
	*out = {};
	out->name = str(mesh.prim_name);
	out->path = str(mesh.abs_path);
	out->double_sided = mesh.doubleSided;
	out->left_handed = !mesh.is_rightHanded;

	const std::vector<uint32_t> &indices = mesh.faceVertexIndices();
	const std::vector<uint32_t> &counts = mesh.faceVertexCounts();
	size_t triangles = counts.size();
	for (uint32_t c : counts) {
		if (c != 3) {
			return 0;
		}
	}
	if (indices.size() != triangles * 3) {
		return 0;
	}

	// The triangle each original face became, for uniform attributes.
	std::vector<uint32_t> face_of(triangles, 0);
	if (!mesh.triangulatedFaceCounts.empty()) {
		size_t t = 0;
		for (size_t f = 0; f < mesh.triangulatedFaceCounts.size(); f++) {
			for (uint32_t k = 0; k < mesh.triangulatedFaceCounts[f] && t < triangles; k++) {
				face_of[t++] = uint32_t(f);
			}
		}
	} else {
		for (size_t t = 0; t < triangles; t++) {
			face_of[t] = uint32_t(t);
		}
	}

	// Each triangle's subset: the GeomSubsets in name order, then the faces that none of them hold.
	std::vector<int32_t> group(triangles, -1);
	std::vector<int32_t> group_material;
	usd->subset_names.clear();
	for (const auto &kv : mesh.material_subsetMap) {
		int32_t g = int32_t(group_material.size());
		group_material.push_back(kv.second.material_id);
		usd->subset_names.push_back(kv.first);
		for (int tri : kv.second.indices()) {
			if (tri >= 0 && size_t(tri) < triangles && group[size_t(tri)] < 0) {
				group[size_t(tri)] = g;
			}
		}
	}
	int32_t rest = int32_t(group_material.size());
	bool any_rest = false;
	for (int32_t &g : group) {
		if (g < 0) {
			g = rest;
			any_rest = true;
		}
	}
	if (any_rest) {
		group_material.push_back(mesh.material_id);
		usd->subset_names.push_back("default");
	}

	bool has_normals = !mesh.normals.empty();
	const tydra::VertexAttribute *uv0 = nullptr, *uv1 = nullptr;
	auto t0 = mesh.texcoords.find(0);
	if (t0 != mesh.texcoords.end() && !t0->second.empty()) {
		uv0 = &t0->second;
	}
	auto t1 = mesh.texcoords.find(1);
	if (t1 != mesh.texcoords.end() && !t1->second.empty()) {
		uv1 = &t1->second;
	}
	bool has_colors = !mesh.vertex_colors.empty();

	size_t corners = triangles * 3;
	usd->positions.assign(corners * 3, 0.0f);
	usd->normals.assign(has_normals ? corners * 3 : 0, 0.0f);
	usd->uv0.assign(uv0 ? corners * 2 : 0, 0.0f);
	usd->uv1.assign(uv1 ? corners * 2 : 0, 0.0f);
	usd->colors.assign(has_colors ? corners * 3 : 0, 1.0f);
	usd->subsets.clear();

	size_t at = 0;
	for (int32_t g = 0; g < int32_t(group_material.size()); g++) {
		size_t first = at;
		for (size_t t = 0; t < triangles; t++) {
			if (group[t] != g) {
				continue;
			}
			for (size_t k = 0; k < 3; k++) {
				size_t corner = t * 3 + k;
				uint32_t vertex = indices[corner];
				if (vertex >= mesh.points.size()) {
					return 0;
				}
				const auto &p = mesh.points[vertex];
				usd->positions[at * 3 + 0] = p[0];
				usd->positions[at * 3 + 1] = p[1];
				usd->positions[at * 3 + 2] = p[2];
				if (has_normals && !attribute_floats(mesh.normals, 3, corner, vertex, face_of[t], &usd->normals[at * 3])) {
					usd->normals.clear();
					has_normals = false;
				}
				if (uv0 && !attribute_floats(*uv0, 2, corner, vertex, face_of[t], &usd->uv0[at * 2])) {
					usd->uv0.clear();
					uv0 = nullptr;
				}
				if (uv1 && !attribute_floats(*uv1, 2, corner, vertex, face_of[t], &usd->uv1[at * 2])) {
					usd->uv1.clear();
					uv1 = nullptr;
				}
				if (has_colors &&
				    !attribute_floats(mesh.vertex_colors, 3, corner, vertex, face_of[t], &usd->colors[at * 3])) {
					usd->colors.clear();
					has_colors = false;
				}
				at++;
			}
		}
		if (at > first) {
			Cn_Usd_Subset s = {};
			s.material = alias_material(usd, group_material[size_t(g)]);
			s.first = int32_t(first);
			s.count = int32_t(at - first);
			usd->subsets.push_back(s);
		}
	}
	// Names last: subset_names no longer grows, so the strings stay put.
	{
		size_t s = 0;
		for (int32_t g = 0; g < int32_t(group_material.size()) && s < usd->subsets.size(); g++) {
			bool used = false;
			for (size_t t = 0; t < triangles && !used; t++) {
				used = group[t] == g;
			}
			if (used) {
				usd->subsets[s++].name = str(usd->subset_names[size_t(g)]);
			}
		}
	}
	if (!has_colors && mesh.has_authored_displayColor) {
		usd->colors.assign(corners * 3, 0.0f);
		for (size_t c = 0; c < corners; c++) {
			usd->colors[c * 3 + 0] = mesh.displayColor[0];
			usd->colors[c * 3 + 1] = mesh.displayColor[1];
			usd->colors[c * 3 + 2] = mesh.displayColor[2];
		}
		has_colors = true;
	}

	out->corner_count = int32_t(corners);
	out->positions = usd->positions.data();
	out->normals = has_normals ? usd->normals.data() : nullptr;
	out->uv0 = uv0 ? usd->uv0.data() : nullptr;
	out->uv1 = uv1 ? usd->uv1.data() : nullptr;
	out->colors = has_colors ? usd->colors.data() : nullptr;
	out->subset_count = int32_t(usd->subsets.size());
	out->subsets = usd->subsets.data();
	return 1;
}

static int32_t channel_of(tydra::UVTexture::Channel c) {
	switch (c) {
	case tydra::UVTexture::Channel::R:
		return CN_USD_CHANNEL_R;
	case tydra::UVTexture::Channel::G:
		return CN_USD_CHANNEL_G;
	case tydra::UVTexture::Channel::B:
		return CN_USD_CHANNEL_B;
	case tydra::UVTexture::Channel::A:
		return CN_USD_CHANNEL_A;
	case tydra::UVTexture::Channel::RGBA:
		return CN_USD_CHANNEL_RGBA;
	default:
		return CN_USD_CHANNEL_RGB;
	}
}

template <typename T>
static Cn_Usd_Input input_of(Cn_Usd *usd, const tydra::ShaderParam<T> &param, bool scalar) {
	Cn_Usd_Input in = {};
	in.texture = -1;
	in.channel = scalar ? CN_USD_CHANNEL_R : CN_USD_CHANNEL_RGB;
	if constexpr (std::is_same_v<T, float>) {
		in.value[0] = in.value[1] = in.value[2] = param.value;
	} else {
		in.value[0] = param.value[0];
		in.value[1] = param.value[1];
		in.value[2] = param.value[2];
	}
	if (param.is_texture() && size_t(param.texture_id) < usd->scene.textures.size()) {
		in.texture = param.texture_id;
		int32_t c = channel_of(usd->scene.textures[size_t(param.texture_id)].connectedOutputChannel);
		// A float input connected to `outputs:rgb` reads the red channel.
		if (scalar && (c == CN_USD_CHANNEL_RGB || c == CN_USD_CHANNEL_RGBA)) {
			c = CN_USD_CHANNEL_R;
		}
		in.channel = c;
	}
	return in;
}

extern "C" void cn_usd_material(Cn_Usd *usd, int32_t index, Cn_Usd_Material *out) {
	const tydra::RenderMaterial &m = usd->scene.materials[size_t(index)];
	*out = {};
	out->name = str(m.name);
	out->path = str(m.abs_path);
	tydra::PreviewSurfaceShader s;
	if (m.surfaceShader.has_value()) {
		out->preview_surface = 1;
		s = *m.surfaceShader;
	}
	out->specular_workflow = s.useSpecularWorkflow;
	out->diffuse = input_of(usd, s.diffuseColor, false);
	out->emissive = input_of(usd, s.emissiveColor, false);
	out->metallic = input_of(usd, s.metallic, true);
	out->roughness = input_of(usd, s.roughness, true);
	out->opacity = input_of(usd, s.opacity, true);
	out->normal = input_of(usd, s.normal, false);
	out->occlusion = input_of(usd, s.occlusion, true);
	out->opacity_threshold = s.opacityThreshold.value;
}

extern "C" void cn_usd_light(Cn_Usd *usd, int32_t index, Cn_Usd_Light *out) {
	const tydra::RenderLight &l = usd->scene.lights[size_t(index)];
	*out = {};
	switch (l.type) {
	case tydra::RenderLight::Type::Dome:
		out->kind = CN_USD_LIGHT_DOME;
		break;
	case tydra::RenderLight::Type::Distant:
		out->kind = CN_USD_LIGHT_DISTANT;
		break;
	default:
		out->kind = CN_USD_LIGHT_OTHER;
	}
	out->name = str(l.name);
	out->path = str(l.abs_path);
	for (int c = 0; c < 3; c++) {
		out->color[c] = l.color[c];
	}
	out->intensity = l.intensity;
	out->exposure = l.exposure;
	for (int r = 0; r < 4; r++) {
		for (int c = 0; c < 4; c++) {
			out->world[r * 4 + c] = l.transform.m[r][c];
		}
	}
	out->texture = str(l.textureFile);
	out->resolved = str(usd->light_resolved[size_t(index)]);
}

static int32_t wrap_of(tydra::UVTexture::WrapMode w) {
	switch (w) {
	case tydra::UVTexture::WrapMode::REPEAT:
		return CN_USD_WRAP_REPEAT;
	case tydra::UVTexture::WrapMode::MIRROR:
		return CN_USD_WRAP_MIRROR;
	case tydra::UVTexture::WrapMode::CLAMP_TO_BORDER:
		return CN_USD_WRAP_BLACK;
	default:
		return CN_USD_WRAP_CLAMP;
	}
}

extern "C" void cn_usd_texture(Cn_Usd *usd, int32_t index, Cn_Usd_Texture *out) {
	const tydra::UVTexture &t = usd->scene.textures[size_t(index)];
	*out = {};
	out->color_space = CN_USD_COLOR_AUTO;
	if (t.texture_image_id >= 0 && size_t(t.texture_image_id) < usd->scene.images.size()) {
		const tydra::TextureImage &image = usd->scene.images[size_t(t.texture_image_id)];
		out->asset = str(image.asset_identifier);
		if (image.sourceColorSpaceName == "sRGB") {
			out->color_space = CN_USD_COLOR_SRGB;
		} else if (image.sourceColorSpaceName == "raw") {
			out->color_space = CN_USD_COLOR_RAW;
		}
	}
	out->resolved = str(usd->resolved[size_t(index)]);
	out->wrap_s = wrap_of(t.wrapS);
	out->wrap_t = wrap_of(t.wrapT);
	out->uv_name = str(t.varname_uv);
	for (int i = 0; i < 4; i++) {
		out->scale[i] = t.scale[i];
		out->bias[i] = t.bias[i];
	}
	out->has_transform = t.has_transform2d;
	out->transform_scale[0] = t.tx_scale[0];
	out->transform_scale[1] = t.tx_scale[1];
	out->transform_rotation = t.tx_rotation;
	out->transform_translation[0] = t.tx_translation[0];
	out->transform_translation[1] = t.tx_translation[1];
}
