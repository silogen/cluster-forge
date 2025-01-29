## Usage

The process of creating and deploying a stack involves 3 to 5 steps depending on your use case.

---

### Step 0: Configure Tools (Optional)

If a required tool or component is missing, add it to the `input/config.yaml` file.

---

### Step 1: Smelt

The `smelt` step normalizes YAML configurations for the selected components.

Run the following command:

```sh
go run . smelt
```
or if using Devbox
```sh
smelt
```

This will generate formatted YAML configs based on your selections.


---

### Step 2: Customize (Optional)

To tailor your configuration, edit files under the `/working` directory.  
This step is optional.

---

### Step 3: Cast

The `cast` step compiles the components into a deployable stack image. By default, an image is created and pushed to an [ephemeral registry](ttl.sh) where it will be available for 12 hours. 

To push the image instead to a registry of your choice, set env variable PUBLISH_IMAGE=true and you will be given the option to specify the registry, image name and tag. 

Run the following command:

```sh
go run . cast
```
or if using Devbox
```sh
cast
```

> **Important:**  
> If you encounter build errors during the `cast` process, you may need to enable **multi-architecture Docker builds** with the following command:
> ```sh
> docker buildx create --name multiarch-builder --use
> ```


---

### Step 4: Temper

**(Work in Progress)**  

