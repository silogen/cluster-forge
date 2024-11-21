use std::{
	collections::HashMap,
	fs,
	io,
	path::Path,
    };
    use log::{error, info};
    use serde::{Deserialize, Serialize};
    use indicatif::{ProgressBar, ProgressStyle};
    
    use crate::utils::{
	copy_yaml_files, remove_empty_yaml_files, Config, remove_yaml_files, create_crossplane_object,
	generate_function_templates,
    };
    
    #[derive(Debug, Serialize, Deserialize)]
    struct Toolbox {
	target_tool: TargetTool,
    }
    
    #[derive(Debug, Serialize, Deserialize)]
    struct TargetTool {
	tool_types: Vec<String>,
    }
    
    pub fn remove_element(slice: &mut Vec<String>, element: &str) {
	slice.retain(|x| x != element);
    }
    
    pub fn fetch_files_and_categorize(
	dir: &str,
	prefix: &str,
    ) -> io::Result<(Vec<String>, Vec<String>, Vec<String>, Vec<String>)> {
	let mut crd_files = Vec::new();
	let mut secret_files = Vec::new();
	let mut external_secret_files = Vec::new();
	let mut object_files = Vec::new();
    
	for entry in fs::read_dir(dir)? {
	    let entry = entry?;
	    let file_name = entry.file_name().into_string().unwrap_or_default();
    
	    if file_name.starts_with(prefix) {
		if file_name.contains("crd") {
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
    
	Ok((crd_files, secret_files, external_secret_files, object_files))
    }
    
    
    pub fn cast(configs: &[Config]) {
	info!("Starting up the menu...");
    
	let mut toolbox = Toolbox {
	    target_tool: TargetTool {
		tool_types: Vec::new(),
	    },
	};
    
	let mut names = vec!["all".to_string()];
	let output_dir = Path::new("./working");
    
	if let Err(err) = fs::read_dir(output_dir).and_then(|entries| {
	    for entry in entries {
		let entry = entry?;
		if entry.file_type()?.is_dir() && entry.file_name() != "pre" {
		    names.push(entry.file_name().into_string().unwrap_or_default());
		}
	    }
	    Ok(())
	}) {
	    error!("Failed to read directory: {:#?}", err);
	    return;
	}

	if let Err(err) = remove_yaml_files(Path::new("./output").to_str().unwrap()) {
		error!("Failed to remove YAML files: {:#?}", err);
	    }
	    
    
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
    
		    if let Ok((crd_files, tool_secret_files, external_secret_files, object_files)) =
			fetch_files_and_categorize("output", tool)
		    {
			config.crd_files.get_or_insert_with(Vec::new).extend(crd_files);
			config.secret_files.get_or_insert_with(Vec::new).extend(tool_secret_files.clone());
			config.object_files.get_or_insert_with(Vec::new).extend(object_files);
			config.external_secret_files.get_or_insert_with(Vec::new).extend(external_secret_files);
			secret_files.extend(tool_secret_files);
		    }
		}
	    }
	};
    
	let pb = ProgressBar::new_spinner();
	pb.set_style(
	    ProgressStyle::default_spinner()
		.template("{spinner:.green} {msg}"),
	);
	pb.enable_steady_tick(100);
	pb.set_message("Preparing your tools...");
    
	prepare_tool();
	pb.finish_with_message("Tools prepared successfully!");
    
	// Generate function templates and copy files
	if let Err(err) = generate_function_templates("output", "output/function-templates.yaml") {
	    error!("Failed to generate function templates: {:#?}", err);
	}
    
	if let Err(err) = copy_yaml_files("cmd/utils/templates", "output") {
	    error!("Failed to copy YAML files: {:#?}", err);
	}
    }
    