use std::{
	collections::HashMap,
	fs,
	io,
	path::{Path, PathBuf},
    };
    use log::{error, info};
    use serde::{Deserialize, Serialize};
    use indicatif::{ProgressBar, ProgressStyle};
    
    use crate::utils::{
	copy_yaml_files, create_crossplane_object, generate_function_templates,
	remove_empty_yaml_files, remove_yaml_files, Config,
    };
    
    #[derive(Debug, Serialize, Deserialize)]
    struct Toolbox {
	target_tool: TargetTool,
    }
    
    #[derive(Debug, Serialize, Deserialize)]
    struct TargetTool {
	tool_types: Vec<String>,
    }
    
    /// Removes an element from a vector by value.
    fn remove_element(slice: &mut Vec<String>, element: &str) {
	slice.retain(|x| x != element);
    }
    
    /// Fetches and categorizes files based on their prefixes.
    fn fetch_files_and_categorize(
	dir: &str,
	prefix: &str,
    ) -> io::Result<(Vec<String>, Vec<String>, Vec<String>, Vec<String>, Vec<String>)> {
	let mut namespace_files = Vec::new();
	let mut crd_files = Vec::new();
	let mut secret_files = Vec::new();
	let mut external_secret_files = Vec::new();
	let mut object_files = Vec::new();
    
	for entry in fs::read_dir(dir)? {
	    let entry = entry?;
	    let file_name = entry.file_name().to_string_lossy().to_string();
    
	    if file_name.starts_with(prefix) {
		if file_name.contains("namespace") {
		    namespace_files.push(file_name);
		} else if file_name.contains("crd") {
		    crd_files.push(file_name);
		} else if file_name.contains("externalsecret") {
		    external_secret_files.push(file_name);
		} else if file_name.contains("secret") {
		    secret_files.push(file_name);
		} else if file_name.contains("object") {
		    object_files.push(file_name);
		}
	    }
	}
    
	Ok((
	    namespace_files,
	    crd_files,
	    secret_files,
	    external_secret_files,
	    object_files,
	))
    }
    
    pub fn cast(configs: &[Config]) {
	info!("Starting the cast process...");
    
	let mut toolbox = Toolbox {
	    target_tool: TargetTool {
		tool_types: Vec::new(),
	    },
	};
    
	let mut names = vec!["all".to_string()];
	let output_dir = Path::new("./working");
    
	// Populate available tool names
	if let Err(err) = fs::read_dir(output_dir).and_then(|entries| {
	    for entry in entries {
		let entry = entry?;
		if entry.file_type()?.is_dir() && entry.file_name() != "pre" {
		    names.push(entry.file_name().to_string_lossy().to_string());
		}
	    }
	    Ok(())
	}) {
	    error!("Failed to read working directory: {:#?}", err);
	    return;
	}
    
	// Interactively ask the user for the tools to process
	let castname = interactively_select_tools(&mut toolbox, &names);
	if castname.is_none() {
	    error!("No tools selected. Aborting.");
	    return;
	}
	let castname = castname.unwrap();
    
	// Remove YAML files from the output directory
	if let Err(err) = remove_yaml_files("./output") {
	    error!("Failed to remove YAML files: {:#?}", err);
	    return;
	}
    
	// Handle 'all' selection
	if toolbox.target_tool.tool_types.contains(&"all".to_string()) {
	    toolbox.target_tool.tool_types.extend(names.clone());
	}
	remove_element(&mut toolbox.target_tool.tool_types, "all");
    
	let mut secret_files = Vec::new();
	let mut prepare_tool = || {
	    let mut config_map: HashMap<String, Config> = configs
		.iter()
		.map(|config| (config.name.clone(), config.clone()))
		.collect();
    
	    for tool in &toolbox.target_tool.tool_types {
		if let Some(config) = config_map.get_mut(tool) {
		    if let Err(err) = create_crossplane_object(config) {
			error!("Error creating crossplane object: {:#?}", err);
			return;
		    }
    
		    if let Err(err) = remove_empty_yaml_files(Path::new("output")) {
			error!("Error removing empty YAML files: {:#?}", err);
			return;
		    }
    
		    if let Ok((
			namespace_files,
			crd_files,
			tool_secret_files,
			external_secret_files,
			object_files,
		    )) = fetch_files_and_categorize("output", tool)
		    {
			config.namespace_files.get_or_insert_with(Vec::new).extend(namespace_files);
			config.crd_files.get_or_insert_with(Vec::new).extend(crd_files);
			config.secret_files.get_or_insert_with(Vec::new).extend(tool_secret_files.clone());
			config.external_secret_files.get_or_insert_with(Vec::new).extend(external_secret_files);
			config.object_files.get_or_insert_with(Vec::new).extend(object_files);
			secret_files.extend(tool_secret_files);
		    }
		}
	    }
    
	    if !secret_files.is_empty() {
		eprintln!("Secrets found. Please address them before proceeding.");
	    }
	};
    
	let pb = ProgressBar::new_spinner();
	pb.set_style(
	    ProgressStyle::default_spinner()
		.template("{spinner:.green} {msg}")
	);
	pb.enable_steady_tick(100);
	pb.set_message("Preparing your tools...");
    
	prepare_tool();
	pb.finish_with_message("Tools prepared successfully!");
    
	if let Err(err) = generate_function_templates("output", "output/function-templates.yaml") {
	    error!("Failed to generate function templates: {:#?}", err);
	}
    
	if let Err(err) = copy_yaml_files("cmd/utils/templates", "output") {
	    error!("Failed to copy YAML files: {:#?}", err);
	}
    
	let package_dir = PathBuf::from("stacks").join(castname);
	if let Err(err) = fs::create_dir_all(&package_dir) {
	    error!("Failed to create package directory: {:#?}", err);
	    return;
	}
    
	let output_dir = Path::new("output");
	if let Ok(entries) = fs::read_dir(output_dir) {
	    for entry in entries.flatten() {
		let src_path = entry.path();
		if src_path.is_file() {
		    let dst_path = package_dir.join(entry.file_name());
		    if let Err(err) = fs::rename(&src_path, &dst_path) {
			error!("Failed to move file {:?}: {:#?}", src_path, err);
		    }
		}
	    }
	}
    
	info!(
	    "Cast completed. Files saved to: {}",
	    package_dir.to_string_lossy()
	);
    }
    
    fn interactively_select_tools(toolbox: &mut Toolbox, names: &[String]) -> Option<String> {
	println!("Cluster Forge: TO THE FORGE! Let's get started.");
	println!("Choose your target tools to set up:");
	for (index, name) in names.iter().enumerate() {
	    println!("{}. {}", index + 1, name);
	}
    
	let mut selected_indices = String::new();
	io::stdin()
	    .read_line(&mut selected_indices)
	    .expect("Failed to read input");
    
	let indices: Vec<usize> = selected_indices
	    .split_whitespace()
	    .filter_map(|s| s.parse::<usize>().ok())
	    .collect();
    
	if indices.is_empty() {
	    return None;
	}
    
	let selected_tools: Vec<String> = indices
	    .into_iter()
	    .filter_map(|i| names.get(i - 1).cloned())
	    .collect();
    
	toolbox.target_tool.tool_types = selected_tools.clone();
	Some(selected_tools.join("_"))
    }
    