use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader};
use std::error::Error;
use std::path::Path;
use serde::{Deserialize, Serialize};
use serde_yaml;
use log::{debug, error, info};

use crate::utils::{template_helm, Config};

#[derive(Debug, Serialize, Deserialize)]
struct K8sObject {
    kind: String,
    api_version: String,
    metadata: Metadata,
}

#[derive(Debug, Serialize, Deserialize)]
struct Metadata {
    name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    namespace: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    labels: Option<HashMap<String, String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    annotations: Option<HashMap<String, String>>,
}

#[derive(Debug)]
struct TargetTool {
    tools: Vec<String>,
}


pub async fn smelt(configs: &Vec<Config>) {
    info!("Starting up the menu...");

    let mut target_tool = TargetTool { tools: Vec::new() };
    let mut names = vec!["all".to_string()];

    for config in configs {
        names.push(config.name.clone());
    }

    target_tool.tools = names.clone();

    if target_tool.tools.contains(&"all".to_string()) {
        for config in configs {
            target_tool.tools.push(config.name.clone());
        }
        target_tool.tools.retain(|tool| tool != "all");
    }

    let config_map: HashMap<String, Config> = configs.iter().cloned().map(|config| (config.name.clone(), config)).collect();

    for tool in &target_tool.tools {
        if let Some(config) = config_map.get(tool) {
            debug!("Running setup for {}", config.name);
            if let Err(e) = prepare_tool(config).await {
                error!("Error preparing tool {}: {}", config.name, e);
            }
        } else {
            error!("Config for tool {} not found", tool);
        }
    }

    print_summary(&target_tool);
}

async fn prepare_tool(config: &Config) -> Result<(), Box<dyn Error>> {
    let namespace_template = r#"apiVersion: v1
kind: Namespace
metadata:
  name: {{ .NamespaceName }}"#;

    let working_dir = format!("working/pre/{}", config.name);

    // Remove old files
    if let Ok(entries) = fs::read_dir(&working_dir) {
        for entry in entries {
            if let Ok(entry) = entry {
                let path = entry.path();
                if path.is_file() && !path.file_name().unwrap().to_str().unwrap().contains("ExternalSecret") {
                    if let Err(e) = fs::remove_file(&path) {
                        error!("Error deleting file {}: {}", path.display(), e);
                    }
                }
            }
        }
    }

    // Helm templating
    if let Err(e) = template_helm(config).await {
        error!("Error templating helm for {}: {}", config.name, e);
        return Ok(()); // Continue with other steps
    }

    // Split YAML
    if let Err(e) = split_yaml(config) {
        error!("Error splitting YAML for {}: {}", config.name, e);
        return Ok(()); // Continue with other steps
    }

    // Check and create namespace object
    let namespace_object_exists = fs::read_dir(format!("working/{}", config.name))
        .map(|entries| {
            entries
                .filter_map(|entry| entry.ok())
                .any(|entry| entry.file_name().to_string_lossy().contains("Namespace"))
        })
        .unwrap_or(false);

    if !namespace_object_exists && config.source_file.is_none() {
        let namespace = &config.namespace;
        let namespace_data = namespace_template.replace("{{ .NamespaceName }}", namespace);

        let namespace_path = format!("working/{}/Namespace_{}.yaml", config.name, config.name);
        
        fs::write(&namespace_path, namespace_data)?;

    }

    Ok(())
}


fn split_yaml(config: &Config) -> Result<(), Box<dyn std::error::Error>> {
    let filename = config.filename.clone().unwrap_or_else(|| format!("working/pre/{}.yaml", config.name));
    if !Path::new(&filename).exists() {
        return Err(format!("File does not exist for tool {}: {}", config.name, filename).into());
    }

    let data = fs::read_to_string(&filename)?;
    let documents: Vec<&str> = data.split("---").collect();

    for doc in documents {
        let cleaned = clean(doc.as_bytes())?;
        let object: K8sObject = serde_yaml::from_slice(&cleaned)?;

        if object.kind.is_empty() || object.api_version.is_empty() {
            error!("YAML object missing `kind` or `apiVersion` for {}", config.name);
            continue;
        }

        let mut object = object;
        if object.metadata.namespace.is_none() {
            object.metadata.namespace = Some(config.namespace.clone());

        }

        let output_filename = format!(
            "working/{}/{}_{}.yaml",
            config.name, object.kind, object.metadata.name
        );
        let updated_yaml = serde_yaml::to_string(&object)?;
        fs::write(output_filename, updated_yaml)?;
    }

    Ok(())
}


fn clean(input: &[u8]) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let mut output = Vec::new();
    let reader = BufReader::new(input);

    for line in reader.lines() {
        let line = line?;
        if line.contains("---") || line.starts_with('#') {
            continue;
        }
        output.extend_from_slice(line.as_bytes());
        output.push(b'\n');
    }

    Ok(output)
}

fn print_summary(toolbox: &TargetTool) {
    println!("Cluster Forge\n\nCompleted: {}.", toolbox.tools.join(", "));
}



